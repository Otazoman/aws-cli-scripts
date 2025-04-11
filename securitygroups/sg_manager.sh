#!/bin/bash

# 変数の設定
RULES_FILE=$1  # ルールを記述したCSVファイル

# 引数の検証
if [ $# -ne 1 ]; then
    echo "使用方法: $0 <ルールファイル>" >&2
    exit 1
fi

# ファイルの存在確認
if [[ ! -f "$RULES_FILE" ]]; then
  echo "ルールファイルが見つかりません: $RULES_FILE" >&2
  exit 1
fi

# VPC識別子（IDまたは名前）からVPC IDを取得する関数
get_vpc_id() {
  local REGION=$1
  local VPC_IDENTIFIER=$2
  # VPC IDの形式かどうかをチェック (^vpc-)
  if [[ $VPC_IDENTIFIER =~ ^vpc- ]]; then
    # VPC IDが存在するか確認
    local VPC_ID=$(aws ec2 describe-vpcs \
      --region ${REGION} \
      --vpc-ids ${VPC_IDENTIFIER} \
      --query "Vpcs[0].VpcId" \
      --output text 2>/dev/null)
  else
    # VPC名で検索
    local VPC_ID=$(aws ec2 describe-vpcs \
      --region ${REGION} \
      --filters "Name=tag:Name,Values=${VPC_IDENTIFIER}" \
      --query "Vpcs[0].VpcId" \
      --output text)
  fi

  if [[ $VPC_ID == "None" || -z $VPC_ID ]]; then
    echo "エラー: VPC '${VPC_IDENTIFIER}' はリージョン '${REGION}' に存在しません。" >&2
    exit 1
  fi
  echo $VPC_ID
}

# プレフィックスリスト名からIDを取得する関数
get_prefix_list_id() {
  local REGION=$1
  local PREFIX_LIST_NAME=$2
  local PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
    --region ${REGION} \
    --filters "Name=prefix-list-name,Values=${PREFIX_LIST_NAME}" \
    --query "PrefixLists[0].PrefixListId" \
    --output text
  )
  if [[ $PREFIX_LIST_ID == "None" ]]; then
    echo ""
  else
    echo $PREFIX_LIST_ID
  fi
}

# セキュリティグループ名からIDを取得する関数
get_security_group_id() {
  local REGION=$1
  local SG_NAME=$2
  local VPC_ID=$3
  local SG_ID=$(aws ec2 describe-security-groups \
    --region ${REGION} \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text)
  if [[ $SG_ID == "None" ]]; then
    echo ""
  else
    echo $SG_ID
  fi
}

# セキュリティグループに同一ルールが既に存在するか確認する関数
rule_exists() {
  local REGION=$1
  local GROUP_ID=$2
  local PROTOCOL=$3
  local FROM_PORT=$4
  local TO_PORT=$5
  local TARGET=$6

  # 既存のルールを取得
  EXISTING_RULES=$(aws ec2 describe-security-group-rules \
    --region ${REGION} \
    --filters "Name=group-id,Values=${GROUP_ID}" \
    --query "SecurityGroupRules[?IpProtocol=='${PROTOCOL}' && FromPort==\`${FROM_PORT}\` && ToPort==\`${TO_PORT}\`]" \
    --output json
  )

  # ターゲットがCIDRの場合
  if [[ ${TARGET} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "${EXISTING_RULES}" | jq -e --arg TARGET "${TARGET}" '.[] | select(.CidrIpv4 == $TARGET)' > /dev/null
    return $?
  # ターゲットがセキュリティグループIDの場合
  elif [[ ${TARGET} =~ ^sg- ]]; then
    echo "${EXISTING_RULES}" | jq -e --arg TARGET "${TARGET}" '.[] | select(.ReferencedGroupInfo.GroupId == $TARGET)' > /dev/null
    return $?
  # ターゲットがプレフィックスリストIDの場合
  elif [[ ${TARGET} =~ ^pl- ]]; then
    echo "${EXISTING_RULES}" | jq -e --arg TARGET "${TARGET}" '.[] | select(.PrefixListId == $TARGET)' > /dev/null
    return $?
  fi

  return 1
}

# 作業対象のセキュリティグループの名前とIDをマッピング
# 存在しない場合は新規で作成
declare -A sg_map
while IFS=, read -r REGION VPC_IDENTIFIER NAME DESCRIPTION
do
  VPCID=$(get_vpc_id ${REGION} ${VPC_IDENTIFIER})
  if [ -z "${sg_map[${REGION}${VPCID}${NAME}]}" ]; then
    sg_id=$(aws ec2 describe-security-groups \
      --region ${REGION} \
      --filters "Name=vpc-id,Values=${VPCID}" "Name=group-name,Values=${NAME}" \
      --query "SecurityGroups[0].GroupId" \
      --output text
    )
    if [[ $sg_id == "None" ]]; then
      echo "新しいセキュリティグループを作成します: ${NAME} (${REGION})"
      sg_map[${REGION}${VPCID}${NAME}]=$(aws ec2 create-security-group \
        --region ${REGION} \
        --group-name ${NAME} \
        --description "${DESCRIPTION}" \
        --vpc-id ${VPCID} \
        --query 'GroupId' \
        --output text
      )
    else
      echo "セキュリティグループが既に存在します: ${NAME} (${REGION})"
      sg_map[${REGION}${VPCID}${NAME}]=$sg_id
    fi
  fi
done << EOS
$(awk 'BEGIN{FS=","; OFS=","} NR>1 {print $1,$2,$3,$4}' ${RULES_FILE} | sort | uniq)
EOS

# 引数にしたファイルを読み込みセキュリティグループのルールを修正
while IFS=, read -r REGION VPC_IDENTIFIER NAME DESCRIPTION ACTION DIRECTION PROTOCOL FROM_PORT TO_PORT TARGET RULE_DESCRIPTION
do
  # ヘッダ行をスキップ
  if [[ "$REGION" == "REGION" ]]; then
    continue
  fi

  VPCID=$(get_vpc_id ${REGION} ${VPC_IDENTIFIER})
  if [ "${ACTION}" == "add" ]; then
    ACT="authorize"
    if [ -z "$RULE_DESCRIPTION" ]; then
      RLDESC=""
    else
      RLDESC=",Description=${RULE_DESCRIPTION}"
    fi
  elif [ "${ACTION}" == "remove" ]; then
    ACT="revoke"
    RLDESC=""
  fi
  
  SCMD="${ACT}-security-group-${DIRECTION}"

  # ターゲットの種類を判定
  if [[ ${TARGET} =~ ^sg- ]]; then
    TARGET_TYPE="GroupId"
  elif [[ ${TARGET} =~ ^pl- ]]; then
    TARGET_TYPE="PrefixListId"
  else
    # セキュリティグループ名の場合
    SG_ID=$(get_security_group_id ${REGION} ${TARGET} ${VPCID})
    if [[ -n $SG_ID ]]; then
      TARGET=$SG_ID
      TARGET_TYPE="GroupId"
    else
      # プレフィックスリスト名の場合
      PL_ID=$(get_prefix_list_id ${REGION} ${TARGET})
      if [[ -n $PL_ID ]]; then
        TARGET=$PL_ID
        TARGET_TYPE="PrefixListId"
      else
        # CIDRブロックの場合
        TARGET_TYPE="CidrIp"
      fi
    fi
  fi

  if [[ $TARGET_TYPE == "GroupId" ]]; then
    RULE_TARGET="UserIdGroupPairs=[{GroupId=${TARGET}${RLDESC}}]"
  elif [[ $TARGET_TYPE == "PrefixListId" ]]; then
    RULE_TARGET="PrefixListIds=[{PrefixListId=${TARGET}${RLDESC}}]"
  else
    RULE_TARGET="IpRanges=[{CidrIp=${TARGET}${RLDESC}}]"
  fi
  
  PACKET="IpProtocol=${PROTOCOL}"
  
  if [ "${PROTOCOL}" != "-1" ]; then
    PACKET="${PACKET},FromPort=${FROM_PORT},ToPort=${TO_PORT}"
  fi
  
  PERMISSIONS="${PACKET},${RULE_TARGET}"

  # addの場合、同一ルールが既に存在するか確認
  if [ "${ACTION}" == "add" ]; then
    if rule_exists ${REGION} ${sg_map[${REGION}${VPCID}${NAME}]} ${PROTOCOL} ${FROM_PORT} ${TO_PORT} ${TARGET}; then
      echo "同一ルールが既に存在します: ${DIRECTION}-${PROTOCOL}-${FROM_PORT}-${TO_PORT}-${TARGET}"
      continue
    fi
  fi

  echo "${ACTION} ルール: セキュリティグループ ${NAME}: ${DIRECTION}-${PROTOCOL}-${FROM_PORT}-${TO_PORT}-${TARGET}"
  aws ec2 ${SCMD} --region ${REGION} --group-id ${sg_map[${REGION}${VPCID}${NAME}]} --ip-permissions "${PERMISSIONS}" 1> /dev/null
  if [ $? -eq 0 ]; then
    echo "${ACTION} ルールの適用に成功しました"
  else
    echo "${ACTION} ルールの適用に失敗しました"
  fi

done << EOS
$(awk 'BEGIN{FS=","; OFS=","} NR>1 {print $0}' ${RULES_FILE})
EOS
