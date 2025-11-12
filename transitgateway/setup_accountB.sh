#!/bin/bash
# スクリプト名: setup_accountB.sh (Spoke Account Setup)
# 概要: params.confに基づき、スポークアカウントのリソース (RAM共有の承認、VPCアタッチメント) を設定する
# 実行方法: ./setup_accountB.sh params.conf

# --- 関数定義 ---

# ログ出力用の関数
log() { echo "INFO: $1"; }
warn() { echo "WARN: $1"; }
error() { echo "ERROR: $1"; exit 1; }
step() { echo -e "\n==================================================\n# $1\n=================================================="; }

# AWSコマンドのラッパー
aws_cmd() {
    local REGION=$1
    shift
    # --output text をすべてのコマンドに適用
    aws "$@" --region "${REGION}" --output text
}

# 汎用リソース状態待機関数
wait_for_state() {
    local REGION=$1
    local RESOURCE_TYPE=$2
    local RESOURCE_ID=$3
    local TARGET_STATE=$4
    local QUERY=$5
    local MAX_WAIT=300
    local INTERVAL=15

    if [ -z "${RESOURCE_ID}" ] || [ "${RESOURCE_ID}" == "None" ]; then return; fi
    log "⏳ ${RESOURCE_TYPE} (${RESOURCE_ID}) が '${TARGET_STATE}' になるのを待機中..."
    
    local ELAPSED=0
    while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
        local CURRENT_STATE
        if [ "${RESOURCE_TYPE}" == "transit-gateway-attachment" ]; then
            CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
        fi

        if [ "${CURRENT_STATE}" == "${TARGET_STATE}" ]; then
            log "✅ ${RESOURCE_TYPE} (${RESOURCE_ID}) は '${TARGET_STATE}' 状態になりました。"
            return 0
        fi
        sleep ${INTERVAL}
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    error "❌ ${RESOURCE_TYPE} (${RESOURCE_ID}) の状態待機がタイムアウトしました。現在の状態: ${CURRENT_STATE}"
}

# スポークVPCのアタッチメント処理
function process_spoke_vpc() {
    local INDEX=$1

    eval "local ENABLED=\${VPC_${INDEX}_ENABLED}"
    if [ "${ENABLED}" != "true" ]; then return; fi

    eval "local ACCOUNT_ID_VAR=\${VPC_${INDEX}_ACCOUNT_ID_VAR}"
    eval "local TGW_INDEX=\${VPC_${INDEX}_ATTACH_TO_TGW_INDEX}"
    eval "local VPC_ID=\${VPC_${INDEX}_VPC_ID}"
    eval "local ATTACHMENT_NAME=\${VPC_${INDEX}_ATTACHMENT_NAME}"
    eval "local SUBNET_NAMES_STR=\${VPC_${INDEX}_ENI_SUBNET_NAMES}"
    eval "local SUBNET_CIDRS_STR=\${VPC_${INDEX}_ENI_SUBNET_CIDRS}"
    eval "local SUBNET_AZS_STR=\${VPC_${INDEX}_ENI_SUBNET_AZS}"
    eval "local RAM_SHARE_NAME=\${VPC_${INDEX}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
    eval "local ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    
    eval "local TGW_REGION=\${TGW_${TGW_INDEX}_REGION}"
    eval "local TGW_NAME=\${TGW_${TGW_INDEX}_NAME}"
    eval "local HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_INDEX}_ACCOUNT_ID_VAR}"
    eval "local HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"

    # このスクリプトはクロスアカウントVPCのみを対象とする
    if [ -z "${RAM_SHARE_NAME}" ]; then return; fi

    CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ]; then
        log "VPC ${INDEX} (${VPC_ID}) はアカウント ${ACCOUNT_ID} のリソースです。現在のプロファイル (${CURRENT_ACCOUNT_ID}) とは異なるためスキップします。"
        return
    fi

    step "VPC ${INDEX} (${VPC_ID}) in ${TGW_REGION} のアタッチメント処理を開始"

    # 1. RAM共有の承認
    log "RAM共有 '${RAM_SHARE_NAME}' の招待を検索・承認します..."
    INVITATION_ARN=$(aws_cmd "${TGW_REGION}" ram get-resource-share-invitations --query "resourceShareInvitations[?resourceShareName=='${RAM_SHARE_NAME}' && status=='PENDING'].resourceShareInvitationArn | [0]")
    
    if [ -n "${INVITATION_ARN}" ] && [ "${INVITATION_ARN}" != "None" ]; then
        log "⏳ PENDING状態の招待 (${INVITATION_ARN}) を承認します..."
        aws_cmd "${TGW_REGION}" ram accept-resource-share-invitation --resource-share-invitation-arn "${INVITATION_ARN}"
        log "✅ 招待を承認しました。共有がACTIVEになるのを待ちます..."
        # 状態が伝播するまで少し待つ
        sleep 15
    else
        log "✅ PENDING状態の招待は見つかりませんでした。既に承認済みか確認します。"
    fi

    # 共有されたTGWのIDを取得
    log "TGW検索条件: HUB_ACCOUNT_ID=${HUB_ACCOUNT_ID}, TGW_NAME=${TGW_NAME}, TGW_REGION=${TGW_REGION}"
    
    # まず RAM共有の状況を確認
    log "RAM共有の状況確認中..."
    aws_cmd "${TGW_REGION}" ram get-resource-share-invitations --query "resourceShareInvitations[?resourceShareName=='${RAM_SHARE_NAME}'].[resourceShareName,status,resourceShareArn]" --output table || log "RAM招待情報取得に失敗"
    
    # 共有リソースを直接検索
    log "共有されているTGWリソースを検索中..."
    SHARED_RESOURCES=$(aws_cmd "${TGW_REGION}" ram get-shared-resources --resource-owner OTHER-ACCOUNTS --resource-type "ec2:TransitGateway" --query 'resources[*].arn' 2>/dev/null)
    log "検出された共有TGWリソース: ${SHARED_RESOURCES}"
    
    local SHARED_TGW_ID=""
    
    # 共有リソースからTGW IDを抽出
    if [ -n "${SHARED_RESOURCES}" ] && [ "${SHARED_RESOURCES}" != "None" ]; then
        SHARED_TGW_ID=$(echo "${SHARED_RESOURCES}" | grep -o 'tgw-[a-z0-9]*' | head -n1)
        log "共有リソースから抽出したTGW ID: ${SHARED_TGW_ID}"
    fi
    
    # フォールバック: Owner IDでTGWを直接検索
    if [ -z "${SHARED_TGW_ID}" ] || [ "${SHARED_TGW_ID}" == "None" ]; then
        log "フォールバック: Owner IDでTGWを直接検索..."
        ALL_TGWS=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=owner-id,Values=${HUB_ACCOUNT_ID}" --query 'TransitGateways[*].[TransitGatewayId,Description,State]' --output table)
        log "ハブアカウントの全TGW:\n${ALL_TGWS}"
        
        SHARED_TGW_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=owner-id,Values=${HUB_ACCOUNT_ID}" "Name=state,Values=available" --query 'TransitGateways[0].TransitGatewayId')
        log "Owner ID検索結果: ${SHARED_TGW_ID}"
    fi
    
    # 最終確認
    if [ -n "${SHARED_TGW_ID}" ] && [ "${SHARED_TGW_ID}" != "None" ]; then
        log "✅ 共有されたTGW ID: ${SHARED_TGW_ID} を検出しました。"
        
        # TGWの詳細を確認
        TGW_DETAILS=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --transit-gateway-ids "${SHARED_TGW_ID}" --query 'TransitGateways[0].[TransitGatewayId,State,OwnerId,Description]' --output table)
        log "検出されたTGWの詳細:\n${TGW_DETAILS}"
    else
        # デバッグ情報を表示してからエラー終了
        log "デバッグ情報:"
        log "- 現在のアカウントID: ${CURRENT_ACCOUNT_ID}"
        log "- ハブアカウントID: ${HUB_ACCOUNT_ID}"
        log "- RAM共有名: ${RAM_SHARE_NAME}"
        log "- TGWリージョン: ${TGW_REGION}"
        
        # 最後の診断として、すべてのRAM共有を確認
        log "全RAM共有状況:"
        aws_cmd "${TGW_REGION}" ram get-resource-shares --resource-owner OTHER-ACCOUNTS --query 'resourceShares[*].[name,status,resourceShareArn]' --output table || log "RAM共有取得に失敗"
        
        error "共有されたTGW IDを検出できませんでした。上記のデバッグ情報を確認してください。"
    fi

    # 2. TGW用サブネットの作成
    read -ra SUBNET_NAMES <<< "${SUBNET_NAMES_STR}"
    read -ra SUBNET_CIDRS <<< "${SUBNET_CIDRS_STR}"
    read -ra SUBNET_AZS <<< "${SUBNET_AZS_STR}"
    local SUBNET_IDS=""
    for subnet_idx in "${!SUBNET_NAMES[@]}"; do
        SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${SUBNET_NAMES[subnet_idx]}" --query 'Subnets[0].SubnetId')
        if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" == "None" ]; then
            log "⏳ サブネット ${SUBNET_NAMES[subnet_idx]} を作成中..."
            SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${SUBNET_CIDRS[subnet_idx]}" --availability-zone "${SUBNET_AZS[subnet_idx]}" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${SUBNET_NAMES[subnet_idx]}},${TAGS}]" --query 'Subnet.SubnetId')
            if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" == "None" ]; then
                error "サブネット ${SUBNET_NAMES[subnet_idx]} の作成に失敗しました。"
            fi
        fi
        SUBNET_IDS+="${SUBNET_ID} "
    done

    # 3. TGWアタッチメントの作成
    log "VPCアタッチメントを検索中: TGW=${SHARED_TGW_ID}, VPC=${VPC_ID}, NAME=${ATTACHMENT_NAME}"
    
    # 削除済み状態のアタッチメントを除外して検索
    ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${SHARED_TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" --query "TransitGatewayVpcAttachments[?State!='deleted' && State!='deleting'].TransitGatewayAttachmentId | [0]")
    
    # Nameタグでの検索もバックアップとして実行
    if [ -z "${ATTACHMENT_ID}" ] || [ "${ATTACHMENT_ID}" == "None" ]; then
        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${SHARED_TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${ATTACHMENT_NAME}" --query "TransitGatewayVpcAttachments[?State!='deleted' && State!='deleting'].TransitGatewayAttachmentId | [0]")
    fi
    
    log "アタッチメント検索結果: ${ATTACHMENT_ID}"
    
    if [ -z "${ATTACHMENT_ID}" ] || [ "${ATTACHMENT_ID}" == "None" ]; then
        log "⏳ アタッチメント ${ATTACHMENT_NAME} を作成中..."
        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 create-transit-gateway-vpc-attachment --transit-gateway-id "${SHARED_TGW_ID}" --vpc-id "${VPC_ID}" --subnet-ids ${SUBNET_IDS} --tag-specifications "ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=${ATTACHMENT_NAME}},${TAGS}]" --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId')
        wait_for_state "${TGW_REGION}" "transit-gateway-attachment" "${ATTACHMENT_ID}" "available" "TransitGatewayVpcAttachments[0].State"
        log "✅ アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) が作成されました。"
    else
        # 既存アタッチメントの状態を確認
        EXISTING_STATE=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${ATTACHMENT_ID}" --query 'TransitGatewayVpcAttachments[0].State')
        log "✅ アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) は既に存在します。状態: ${EXISTING_STATE}"
    fi

    # 4. VPCルートテーブルの設定
    # このVPCから他の全てのVPCへのルートを追加する
    eval "local RT_IDS_STR=\${VPC_${INDEX}_ROUTE_TABLE_IDS}"
    read -ra RT_IDS <<< "${RT_IDS_STR}"
    for rt_id in "${RT_IDS[@]}"; do
        for other_vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
            if [ "${INDEX}" != "${other_vpc_idx}" ]; then
                local DEST_CIDR=${ALL_VPC_CIDRS[${other_vpc_idx}]}
                log "VPC RT ${rt_id} にルートを追加: ${DEST_CIDR} -> ${SHARED_TGW_ID}"
                aws_cmd "${TGW_REGION}" ec2 create-route --route-table-id "${rt_id}" --destination-cidr-block "${DEST_CIDR}" --transit-gateway-id "${SHARED_TGW_ID}" >/dev/null 2>&1 || log "ルート ${DEST_CIDR} は既に存在するか、作成に失敗しました。"
            fi
        done
    done
}

# --- メイン処理 ---

START_TIME=$(date +%s)
log "スクリプト開始: $(date)"

# パラメータファイルの読み込み
if [ -z "$1" ]; then error "パラメータファイルを指定してください。"; fi
source "$1"

# 全VPCのCIDR情報を事前に収集
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

step "スポークアカウントのVPCアタッチメント処理を開始"

# VPC設定のデバッグ情報を表示
log "デバッグ: 収集されたVPC CIDR情報:"
for vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
    log "- VPC ${vpc_idx}: ${ALL_VPC_CIDRS[${vpc_idx}]}"
done

i=1
while eval "test -v VPC_${i}_ENABLED"; do
    eval "ENABLED=\${VPC_${i}_ENABLED}"
    eval "ACCOUNT_ID_VAR=\${VPC_${i}_ACCOUNT_ID_VAR}"
    eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    eval "RAM_SHARE_NAME=\${VPC_${i}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
    
    log "デバッグ: VPC ${i} - ENABLED=${ENABLED}, ACCOUNT_ID=${ACCOUNT_ID}, RAM_SHARE=${RAM_SHARE_NAME}"
    
    # VPCの処理対象かどうかを確認
    CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ "${ENABLED}" == "true" ] && [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ]; then
        log "VPC ${i} を処理対象として実行します。"
        process_spoke_vpc $i
        log "VPC ${i} の処理が完了しました。"
    else
        log "VPC ${i} は処理対象外です (ENABLED=${ENABLED}, 同一アカウント=$([[ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ]] && echo "Yes" || echo "No"), RAM設定=$([[ -n "${RAM_SHARE_NAME}" ]] && echo "Yes" || echo "No"))"
    fi
    
    log "次のVPCに進みます: i=${i} -> $((i + 1))"
    i=$((i + 1))
done

log "VPC処理ループが終了しました。最終的な i 値: ${i}"

step "🎉 スポークアカウントの設定が完了しました。"

END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED_TIME / 60))
SECONDS=$((ELAPSED_TIME % 60))

log "スクリプト終了: $(date)"
log "総経過時間: ${MINUTES} 分 ${SECONDS} 秒"
