#!/bin/bash
# スクリプト名: delete.sh (Unified Hub/Spoke Cleanup)
# 概要: params.confに基づき、現在のAWSアカウントの役割を判断し、関連する
#    Transit Gatewayリソースを全て削除する。
# 実行方法: ./delete.sh params.conf

# --- 関数定義 ---

# ログ出力用の関数
log() { echo "INFO: $1"; }
warn() { echo "WARN: $1" >&2; } # 警告も標準エラーに出力
# エラー発生時に標準エラーに出力し、スクリプトを終了
error() { echo "ERROR: $1" >&2; exit 1; } 
step() { echo -e "\n==================================================\n# $1\n=================================================="; }

# AWSコマンドのラッパー
aws_cmd() {
  local REGION=$1
  shift
  aws "$@" --region "${REGION}" --output text
}

# 汎用リソース削除待機関数
wait_for_resource_deleted() {
  local REGION=$1
  local RESOURCE_TYPE=$2
  local RESOURCE_ID=$3
  local MAX_WAIT=360
  local INTERVAL=15

  if [ -z "${RESOURCE_ID}" ] || [ "${RESOURCE_ID}" == "None" ]; then return; fi
  log "${RESOURCE_TYPE} (${RESOURCE_ID}) が完全に削除されるのを待機中..."
  
  local ELAPSED=0
  while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
    local STATE
    case "${RESOURCE_TYPE}" in
      "transit-gateway")
        STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --transit-gateway-ids "${RESOURCE_ID}" --query 'TransitGateways[0].State' 2>/dev/null)
        ;;
      "transit-gateway-attachment" | "transit-gateway-vpc-attachment")
        STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query 'TransitGatewayVpcAttachments[0].State' 2>/dev/null)
        ;;
      "transit-gateway-peering-attachment")
        STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-peering-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query 'TransitGatewayPeeringAttachments[0].State' 2>/dev/null)
        ;;
    esac

    # describe APIが空の結果を返した場合、リソースは存在しない（削除済み）と判断
    if [ -z "${STATE}" ] || [ "${STATE}" == "deleted" ]; then
      log "${RESOURCE_TYPE} (${RESOURCE_ID}) は削除されました。"
      return 0
    fi
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  warn "${RESOURCE_TYPE} (${RESOURCE_ID}) の削除待機がタイムアウトしました。現在の状態: ${STATE}"
}

# --- メイン処理 ---

START_TIME=$(date +%s)
log "スクリプト開始: $(date)"

# パラメータファイルの読み込み
if [ -z "$1" ]; then error "パラメータファイルを指定してください。"; fi
source "$1"

# 現在のアカウントIDを取得
CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "${CURRENT_ACCOUNT_ID}" ]; then error "AWSアカウントIDを取得できませんでした。"; fi
log "現在の実行アカウント: ${CURRENT_ACCOUNT_ID}"

# 全VPCのCIDR情報を収集
declare -A ALL_VPC_CIDRS
i=1
while eval "test -v VPC_${i}_ENABLED"; do
  eval "ENABLED=\${VPC_${i}_ENABLED}"
  if [ "${ENABLED}" == "true" ]; then
    eval "CIDR=\${VPC_${i}_VPC_CIDR}"
    ALL_VPC_CIDRS[${i}]=${CIDR}
  fi
  i=$((i + 1))
done

step "1. ルーティングの削除"
# VPCルートテーブルからのルート削除 (全アカウント共通)
v_idx=1
while eval "test -v VPC_${v_idx}_ENABLED"; do
  eval "ENABLED=\${VPC_${v_idx}_ENABLED}"
  eval "ACCOUNT_ID_VAR=\${VPC_${v_idx}_ACCOUNT_ID_VAR}"
  eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
  if [ "${ENABLED}" == "true" ] && [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
    eval "TGW_IDX=\${VPC_${v_idx}_ATTACH_TO_TGW_INDEX}"
    eval "TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
    eval "RT_IDS_STR=\${VPC_${v_idx}_ROUTE_TABLE_IDS}"
    read -ra RT_IDS <<< "${RT_IDS_STR}"
    for rt_id in "${RT_IDS[@]}"; do
      for other_vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
        if [ "${v_idx}" != "${other_vpc_idx}" ]; then
          DEST_CIDR=${ALL_VPC_CIDRS[${other_vpc_idx}]}
          log "VPC RT ${rt_id} からルート ${DEST_CIDR} を削除中..."
          aws_cmd "${TGW_REGION}" ec2 delete-route --route-table-id "${rt_id}" --destination-cidr-block "${DEST_CIDR}" >/dev/null 2>&1
        fi
      done
    done
  fi
  v_idx=$((v_idx + 1))
done

# TGW静的ルートの削除 (ハブアカウントのみ)
p_idx=1
while eval "test -v PEERING_${p_idx}_ENABLED"; do
  eval "ENABLED=\${PEERING_${p_idx}_ENABLED}"

    # TGW Aのインデックスを取得
    eval "TGW_A_IDX=\${PEERING_${p_idx}_TGW_A_INDEX}"
    
    # TGW AのACCOUNT_ID_VAR変数名 (例: TGW_1_ACCOUNT_ID_VAR) の値 (例: ACCOUNT_A_ID_VAR) を取得
    TGW_ACCOUNT_ID_VAR_NAME="TGW_${TGW_A_IDX}_ACCOUNT_ID_VAR"
    eval "TGW_A_ACCOUNT_VAR=\${${TGW_ACCOUNT_ID_VAR_NAME}}"
    
    # TGW_A_ACCOUNT_VAR が指す変数から最終的なアカウントIDの値を取得
    eval "TGW_A_ACCOUNT_ID=\${${TGW_A_ACCOUNT_VAR}}"

  if [ "${ENABLED}" == "true" ] && [ "${CURRENT_ACCOUNT_ID}" == "${TGW_A_ACCOUNT_ID}" ]; then
    log "HUB: ピアリング ${p_idx} の静的ルートを削除します。"
    # TGW A -> TGW B へのルートを削除
    eval "TGW_B_IDX=\${PEERING_${p_idx}_TGW_B_INDEX}"
    eval "TGW_A_REGION=\${TGW_${TGW_A_IDX}_REGION}"
    eval "TGW_A_NAME=\${TGW_${TGW_A_IDX}_NAME}"
    TGW_A_ID=$(aws_cmd "${TGW_A_REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${TGW_A_NAME}" --query 'TransitGateways[0].TransitGatewayId')
    if [ -n "${TGW_A_ID}" ]; then
      TGW_RT_ID=$(aws_cmd "${TGW_A_REGION}" ec2 describe-transit-gateway-route-tables --filters "Name=transit-gateway-id,Values=${TGW_A_ID}" "Name=default-association-route-table,Values=true" --query "TransitGatewayRouteTables[0].TransitGatewayRouteTableId")
      for vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
        eval "ATTACH_TGW_IDX=\${VPC_${vpc_idx}_ATTACH_TO_TGW_INDEX}"
        if [ "${ATTACH_TGW_IDX}" == "${TGW_B_IDX}" ]; then
          DEST_CIDR=${ALL_VPC_CIDRS[${vpc_idx}]}
          aws_cmd "${TGW_A_REGION}" ec2 delete-transit-gateway-route --destination-cidr-block "${DEST_CIDR}" --transit-gateway-route-table-id "${TGW_RT_ID}" >/dev/null 2>&1
        fi
      done
    fi
    # 逆方向も同様に削除
    eval "TGW_B_REGION=\${TGW_${TGW_B_IDX}_REGION}"
    eval "TGW_B_NAME=\${TGW_${TGW_B_IDX}_NAME}"
    TGW_B_ID=$(aws_cmd "${TGW_B_REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${TGW_B_NAME}" --query 'TransitGateways[0].TransitGatewayId')
    if [ -n "${TGW_B_ID}" ]; then
      TGW_RT_ID=$(aws_cmd "${TGW_B_REGION}" ec2 describe-transit-gateway-route-tables --filters "Name=transit-gateway-id,Values=${TGW_B_ID}" "Name=default-association-route-table,Values=true" --query "TransitGatewayRouteTables[0].TransitGatewayRouteTableId")
      for vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
        eval "ATTACH_TGW_IDX=\${VPC_${vpc_idx}_ATTACH_TO_TGW_INDEX}"
        if [ "${ATTACH_TGW_IDX}" == "${TGW_A_IDX}" ]; then
          DEST_CIDR=${ALL_VPC_CIDRS[${vpc_idx}]}
          aws_cmd "${TGW_B_REGION}" ec2 delete-transit-gateway-route --destination-cidr-block "${DEST_CIDR}" --transit-gateway-route-table-id "${TGW_RT_ID}" >/dev/null 2>&1
        fi
      done
    fi
  fi
  p_idx=$((p_idx + 1))
done

step "2. RAM共有の削除 (ハブアカウントのみ)"
v_idx=1
while eval "test -v VPC_${v_idx}_ENABLED"; do
 eval "ENABLED=\${VPC_${v_idx}_ENABLED}"
 eval "RAM_SHARE_NAME=\${VPC_${v_idx}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
 eval "TGW_IDX=\${VPC_${v_idx}_ATTACH_TO_TGW_INDEX}"
 eval "HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_IDX}_ACCOUNT_ID_VAR}"
 eval "HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"

 if [ "${ENABLED}" == "true" ] && [ -n "${RAM_SHARE_NAME}" ] && [ "${CURRENT_ACCOUNT_ID}" == "${HUB_ACCOUNT_ID}" ]; then
  eval "TGW_REGION=\${TGW_${TGW_IDX}_REGION}"

  # 1. RAM共有ARNを名前で特定
  SHARE_ARN=$(aws_cmd "${TGW_REGION}" ram get-resource-shares --resource-owner SELF --name "${RAM_SHARE_NAME}" \
   --query "resourceShares[?resourceShareArn | contains(@, 'arn:aws:ram:${TGW_REGION}:${CURRENT_ACCOUNT_ID}:')].resourceShareArn | [0]")

  if [ -n "${SHARE_ARN}" ] && [ "${SHARE_ARN}" != "None" ]; then
   log "HUB: RAM共有 ${RAM_SHARE_NAME} (${SHARE_ARN}) を削除中..."
   
   # 2. 関連付けられている全てのプリンシパルを取得
   PRINCIPALS=$(aws_cmd "${TGW_REGION}" ram get-resource-share-associations --association-type PRINCIPAL --resource-share-arns "${SHARE_ARN}" \
    --query 'resourceShareAssociations[].associatedEntity' | tr '\n' ' ') # tr '\t' ' ' を tr '\n' ' ' に変更して出力形式に対応

   if [ -n "${PRINCIPALS}" ]; then
    log "HUB: 関連付けられたプリンシパル ${PRINCIPALS} を解除中..."
    # 3. 関連付け解除
    aws_cmd "${TGW_REGION}" ram disassociate-resource-share --resource-share-arn "${SHARE_ARN}" --principals ${PRINCIPALS} >/dev/null 2>&1
    sleep 5 # 解除処理の開始を待つ
   fi

   # 4. 共有削除
   log "HUB: RAM共有 ${RAM_SHARE_NAME} を削除..."
   aws_cmd "${TGW_REGION}" ram delete-resource-share --resource-share-arn "${SHARE_ARN}"
   # 共有削除は非同期なので、成功したと仮定して次に進む
  fi
 fi
 v_idx=$((v_idx + 1))
done

step "3. 全アタッチメントの削除"
# 包括的なアタッチメント削除 (TGWごとに全アタッチメントを削除)
t_idx=1
while eval "test -v TGW_${t_idx}_REGION"; do
  eval "ACCOUNT_ID_VAR=\${TGW_${t_idx}_ACCOUNT_ID_VAR}"
  eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
  if [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
    eval "REGION=\${TGW_${t_idx}_REGION}"
    eval "NAME=\${TGW_${t_idx}_NAME}"
    
    # TGW IDを取得
    TGW_ID=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${NAME}" "Name=state,Values=available,pending" --query 'TransitGateways[0].TransitGatewayId')
    
    if [ -n "${TGW_ID}" ] && [ "${TGW_ID}" != "None" ]; then
      log "HUB: TGW ${NAME} (${TGW_ID}) の全アタッチメントを削除します..."
      
      # 1. 全VPCアタッチメントを取得して削除
      VPC_ATTACHMENTS=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments \
        --filters "Name=transit-gateway-id,Values=${TGW_ID}" \
        --query "TransitGatewayVpcAttachments[?State!='deleted' && State!='deleting' && State!='failed'].TransitGatewayAttachmentId" | tr '\n' ' ')
      
      for attachment_id in ${VPC_ATTACHMENTS}; do
        if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
          log "VPCアタッチメント ${attachment_id} を削除中..."
          ERROR_OUTPUT=$(aws ec2 delete-transit-gateway-vpc-attachment --region "${REGION}" --transit-gateway-attachment-id "${attachment_id}" 2>&1 >/dev/null)
          if [ $? -ne 0 ]; then
            warn "VPCアタッチメント ${attachment_id} の削除に失敗: ${ERROR_OUTPUT}"
          else
            wait_for_resource_deleted "${REGION}" "transit-gateway-vpc-attachment" "${attachment_id}"
          fi
        fi
      done
      
      # 2. 全ピアリングアタッチメントを取得して削除
      PEERING_ATTACHMENTS=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-peering-attachments \
        --filters "Name=transit-gateway-id,Values=${TGW_ID}" \
        --query "TransitGatewayPeeringAttachments[?State!='deleted' && State!='deleting' && State!='failed'].TransitGatewayAttachmentId" | tr '\n' ' ')
      
      for attachment_id in ${PEERING_ATTACHMENTS}; do
        if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
          log "ピアリングアタッチメント ${attachment_id} を削除中..."
          ERROR_OUTPUT=$(aws ec2 delete-transit-gateway-peering-attachment --region "${REGION}" --transit-gateway-attachment-id "${attachment_id}" 2>&1 >/dev/null)
          if [ $? -ne 0 ]; then
            warn "ピアリングアタッチメント ${attachment_id} の削除に失敗: ${ERROR_OUTPUT}"
          else
            wait_for_resource_deleted "${REGION}" "transit-gateway-peering-attachment" "${attachment_id}"
          fi
        fi
      done
      
      # 3. その他のアタッチメント（Direct Connect Gateway等）も削除
      OTHER_ATTACHMENTS=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-attachments \
        --filters "Name=transit-gateway-id,Values=${TGW_ID}" \
        --query "TransitGatewayAttachments[?State!='deleted' && State!='deleting' && State!='failed' && ResourceType!='vpc' && ResourceType!='peering'].TransitGatewayAttachmentId" | tr '\n' ' ')
      
      for attachment_id in ${OTHER_ATTACHMENTS}; do
        if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
          # リソースタイプを確認
          RESOURCE_TYPE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-attachments \
            --transit-gateway-attachment-ids "${attachment_id}" \
            --query "TransitGatewayAttachments[0].ResourceType")
          log "その他のアタッチメント ${attachment_id} (タイプ: ${RESOURCE_TYPE}) を削除中..."
          
          # リソースタイプに応じて適切な削除コマンドを実行
          case "${RESOURCE_TYPE}" in
            "direct-connect-gateway")
              ERROR_OUTPUT=$(aws ec2 delete-transit-gateway-direct-connect-gateway-attachment --region "${REGION}" --transit-gateway-attachment-id "${attachment_id}" 2>&1 >/dev/null)
              ;;
            "vpn")
              ERROR_OUTPUT=$(aws ec2 delete-transit-gateway-vpn-attachment --region "${REGION}" --transit-gateway-attachment-id "${attachment_id}" 2>&1 >/dev/null)
              ;;
            *)
              warn "未対応のアタッチメントタイプ ${RESOURCE_TYPE} (${attachment_id}) をスキップします"
              continue
              ;;
          esac
          
          if [ $? -ne 0 ]; then
            warn "${RESOURCE_TYPE}アタッチメント ${attachment_id} の削除に失敗: ${ERROR_OUTPUT}"
          fi
        fi
      done
    fi
  fi
  t_idx=$((t_idx + 1))
done

# スポークアカウント用のVPCアタッチメント削除
v_idx=1
while eval "test -v VPC_${v_idx}_ENABLED"; do
  eval "ENABLED=\${VPC_${v_idx}_ENABLED}"
  eval "ACCOUNT_ID_VAR=\${VPC_${v_idx}_ACCOUNT_ID_VAR}"
  eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
  
  # スポークアカウントでのみ実行
  if [ "${ENABLED}" == "true" ] && [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
    eval "TGW_IDX=\${VPC_${v_idx}_ATTACH_TO_TGW_INDEX}"
    eval "HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_IDX}_ACCOUNT_ID_VAR}"
    eval "HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"
    
    # スポークアカウントの場合のみ処理
    if [ "${CURRENT_ACCOUNT_ID}" != "${HUB_ACCOUNT_ID}" ]; then
      eval "TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
      eval "VPC_ID=\${VPC_${v_idx}_VPC_ID}"
      
      # 共有されたTGWのIDを取得
      SHARED_TGW_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=owner-id,Values=${HUB_ACCOUNT_ID}" "Name=state,Values=available" --query 'TransitGateways[0].TransitGatewayId')
      
      if [ -n "${SHARED_TGW_ID}" ] && [ "${SHARED_TGW_ID}" != "None" ]; then
        # このVPCのアタッチメントを検索
        VPC_ATTACHMENTS=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments \
          --filters "Name=transit-gateway-id,Values=${SHARED_TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" \
          --query "TransitGatewayVpcAttachments[?State!='deleted' && State!='deleting'].TransitGatewayAttachmentId" | tr '\n' ' ')
        
        for attachment_id in ${VPC_ATTACHMENTS}; do
          if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
            log "SPOKE: VPCアタッチメント ${attachment_id} を削除中..."
            ERROR_OUTPUT=$(aws ec2 delete-transit-gateway-vpc-attachment --region "${TGW_REGION}" --transit-gateway-attachment-id "${attachment_id}" 2>&1 >/dev/null)
            if [ $? -ne 0 ]; then
              warn "SPOKE: VPCアタッチメント ${attachment_id} の削除に失敗: ${ERROR_OUTPUT}"
            else
              wait_for_resource_deleted "${TGW_REGION}" "transit-gateway-vpc-attachment" "${attachment_id}"
            fi
          fi
        done
      fi
    fi
  fi
  v_idx=$((v_idx + 1))
done


step "4. TGW本体の削除 (ハブアカウントのみ)"
t_idx=1
while eval "test -v TGW_${t_idx}_REGION"; do
  eval "ACCOUNT_ID_VAR=\${TGW_${t_idx}_ACCOUNT_ID_VAR}"
  eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
  if [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
    eval "REGION=\${TGW_${t_idx}_REGION}"
    eval "NAME=\${TGW_${t_idx}_NAME}"
    TGW_ID=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${NAME}" --query "TransitGateways[?State!='deleted'].TransitGatewayId | [0]")
    if [ -n "${TGW_ID}" ] && [ "${TGW_ID}" != "None" ]; then
      
            # --- TGW削除前の待機ロジック (IncorrectStateエラー対策) ---
            log "HUB: TGW ${NAME} (${TGW_ID}) の全てのアタッチメントが完全に削除されるのを待機中..."
            ATTACHMENT_MAX_WAIT=360 
            ATTACHMENT_ELAPSED=0    
            ATTACHMENT_INTERVAL=15  
            
            # ATTACHMENT_ELAPSEDが最大待機時間未満の場合にループを継続
            while [ ${ATTACHMENT_ELAPSED} -lt ${ATTACHMENT_MAX_WAIT} ]; do
                # pending, available, modifying deleting 状態のアタッチメントがないかチェック
                ATTACHMENTS=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-attachments \
                    --filters "Name=transit-gateway-id,Values=${TGW_ID}" "Name=state,Values=pending,available,modifying,deleting" \
                    --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" | tr '\n' ' ')
                    
                if [ -z "${ATTACHMENTS}" ]; then
                    log "全アタッチメントの削除を確認しました。"
                    break
                fi
                
                warn "未削除のアタッチメントが残っています: ${ATTACHMENTS}. 待機中..."
                sleep ${ATTACHMENT_INTERVAL}
                ATTACHMENT_ELAPSED=$((ATTACHMENT_ELAPSED + ATTACHMENT_INTERVAL))
            done

            if [ -n "${ATTACHMENTS}" ]; then
                # タイムアウト時にエラーを出力し、スクリプトを終了
                error "TGW ${TGW_ID} のアタッチメントの削除待機がタイムアウトしました。手動で確認してください。"
            fi
            # ------------------------------------------------------------------

      log "HUB: TGW ${NAME} (${TGW_ID}) を削除中..."
      aws_cmd "${REGION}" ec2 delete-transit-gateway --transit-gateway-id "${TGW_ID}"
      wait_for_resource_deleted "${REGION}" "transit-gateway" "${TGW_ID}"
    fi
  fi
  t_idx=$((t_idx + 1))
done

step "5. ENI用サブネットの削除 (全アカウント共通)"
v_idx=1
while eval "test -v VPC_${v_idx}_ENABLED"; do
  eval "ENABLED=\${VPC_${v_idx}_ENABLED}"
  eval "ACCOUNT_ID_VAR=\${VPC_${v_idx}_ACCOUNT_ID_VAR}"
  eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
  if [ "${ENABLED}" == "true" ] && [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
    eval "TGW_IDX=\${VPC_${v_idx}_ATTACH_TO_TGW_INDEX}"
    eval "TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
    eval "VPC_ID=\${VPC_${v_idx}_VPC_ID}"
    eval "SUBNET_NAMES_STR=\${VPC_${v_idx}_ENI_SUBNET_NAMES}"
    read -ra SUBNET_NAMES <<< "${SUBNET_NAMES_STR}"
    for name in "${SUBNET_NAMES[@]}"; do
      SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" --query 'Subnets[0].SubnetId')
      if [ -n "${SUBNET_ID}" ] && [ "${SUBNET_ID}" != "None" ]; then
        log "サブネット ${name} (${SUBNET_ID}) を削除中..."
        aws_cmd "${TGW_REGION}" ec2 delete-subnet --subnet-id "${SUBNET_ID}" >/dev/null 2>&1 || warn "サブネット ${name} の削除に失敗しました。ENIがまだ存在している可能性があります。"
      fi
    done
  fi
  v_idx=$((v_idx + 1))
done

step "クリーンアップ処理が完了しました。"
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
log "総経過時間: $((ELAPSED_TIME / 60)) 分 $((ELAPSED_TIME % 60)) 秒"
