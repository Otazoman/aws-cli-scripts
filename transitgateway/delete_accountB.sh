#!/bin/bash
# スクリプト名: delete_accountB.sh (Spoke Account Cleanup)
# 概要: params.confに基づき、スポークアカウントのTransit Gateway関連リソースを削除する
# 実行方法: ./delete_accountB.sh params.conf

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
    aws "$@" --region "${REGION}" --output text
}

# 汎用リソース削除待機関数
wait_for_attachment_deleted() {
    local REGION=$1
    local ATTACHMENT_ID=$2
    local MAX_WAIT=300
    local INTERVAL=15

    if [ -z "${ATTACHMENT_ID}" ]; then return; fi
    log "⏳ アタッチメント (${ATTACHMENT_ID}) が完全に削除されるのを待機中..."
    
    local ELAPSED=0
    while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
        local STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${ATTACHMENT_ID}" --query 'TransitGatewayVpcAttachments[0].State' 2>/dev/null)
        if [ -z "${STATE}" ] || [ "${STATE}" == "deleted" ]; then
            log "✅ アタッチメント (${ATTACHMENT_ID}) は削除されました。"
            return 0
        fi
        sleep ${INTERVAL}
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    warn "❌ アタッチメント (${ATTACHMENT_ID}) の削除待機がタイムアウトしました。現在の状態: ${STATE}"
}

# --- メイン処理 ---

START_TIME=$(date +%s)
log "スクリプト開始: $(date +"%Y-%m-%d %H:%M:%S %Z")"

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

CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

step "スポークアカウントのクリーンアップ処理を開始"
v_idx=1
while eval "test -v VPC_${v_idx}_ENABLED"; do
    eval "ENABLED=\${VPC_${v_idx}_ENABLED}"
    eval "ACCOUNT_ID_VAR=\${VPC_${v_idx}_ACCOUNT_ID_VAR}"
    eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    eval "RAM_SHARE_NAME=\${VPC_${v_idx}_CROSS_ACCOUNT_RAM_SHARE_NAME}"

    # 現在のプロファイルに一致するクロスアカウントVPCのみを処理
    if [ "${ENABLED}" == "true" ] && [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ]; then
        eval "TGW_IDX=\${VPC_${v_idx}_ATTACH_TO_TGW_INDEX}"
        eval "TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
        eval "TGW_NAME=\${TGW_${TGW_IDX}_NAME}"
        eval "HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_IDX}_ACCOUNT_ID_VAR}"
        eval "HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"
        eval "VPC_ID=\${VPC_${v_idx}_VPC_ID}"
        eval "RT_IDS_STR=\${VPC_${v_idx}_ROUTE_TABLE_IDS}"
        
        log "VPC ${v_idx} (${VPC_ID}) のクリーンアップを開始..."

        # 共有TGWのIDを取得
        log "TGW検索: HUB_ACCOUNT_ID=${HUB_ACCOUNT_ID}, TGW_NAME=${TGW_NAME}, REGION=${TGW_REGION}"
        
        # Owner IDのみで検索（Nameタグに依存しない）
        SHARED_TGW_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=owner-id,Values=${HUB_ACCOUNT_ID}" "Name=state,Values=available" --query 'TransitGateways[0].TransitGatewayId')
        log "TGW検索結果: ${SHARED_TGW_ID}"
        
        if [ -z "${SHARED_TGW_ID}" ] || [ "${SHARED_TGW_ID}" == "None" ]; then
            warn "共有TGWが見つかりません。ルートとアタッチメントの削除をスキップします。"
        else
            # 1. VPCルートテーブルからのルート削除
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

            # 2. VPCアタッチメントの削除
            log "VPCアタッチメントを検索中: TGW=${SHARED_TGW_ID}, VPC=${VPC_ID}"
            ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${SHARED_TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" --query "TransitGatewayVpcAttachments[?State!='deleted'].TransitGatewayAttachmentId | [0]")
            log "アタッチメント検索結果: ${ATTACHMENT_ID}"
            
            if [ -n "${ATTACHMENT_ID}" ] && [ "${ATTACHMENT_ID}" != "None" ]; then
                log "VPCアタッチメント ${ATTACHMENT_ID} を削除中..."
                aws_cmd "${TGW_REGION}" ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id "${ATTACHMENT_ID}"
                wait_for_attachment_deleted "${TGW_REGION}" "${ATTACHMENT_ID}"
            else
                log "削除対象のVPCアタッチメントが見つかりませんでした。"
            fi
        fi

        # 3. ENI用サブネットの削除
        eval "SUBNET_NAMES_STR=\${VPC_${v_idx}_ENI_SUBNET_NAMES}"
        read -ra SUBNET_NAMES <<< "${SUBNET_NAMES_STR}"
        for name in "${SUBNET_NAMES[@]}"; do
            SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" --query 'Subnets[0].SubnetId')
            if [ -n "${SUBNET_ID}" ] && [ "${SUBNET_ID}" != "None" ]; then
                log "サブネット ${name} (${SUBNET_ID}) の依存関係を確認中..."
                
                # サブネット内のENIを削除
                ENI_IDS=$(aws_cmd "${TGW_REGION}" ec2 describe-network-interfaces --filters "Name=subnet-id,Values=${SUBNET_ID}" --query "NetworkInterfaces[?Status!='available'].NetworkInterfaceId" | tr '\t' ' ')
                for eni_id in ${ENI_IDS}; do
                    if [ -n "${eni_id}" ] && [ "${eni_id}" != "None" ]; then
                        log "ENI ${eni_id} をデタッチ中..."
                        ATTACHMENT_ID_ENI=$(aws_cmd "${TGW_REGION}" ec2 describe-network-interfaces --network-interface-ids "${eni_id}" --query 'NetworkInterfaces[0].Attachment.AttachmentId')
                        if [ -n "${ATTACHMENT_ID_ENI}" ] && [ "${ATTACHMENT_ID_ENI}" != "None" ]; then
                            aws_cmd "${TGW_REGION}" ec2 detach-network-interface --attachment-id "${ATTACHMENT_ID_ENI}" >/dev/null 2>&1
                            sleep 10 # デタッチ完了を待機
                        fi
                        log "ENI ${eni_id} を削除中..."
                        aws_cmd "${TGW_REGION}" ec2 delete-network-interface --network-interface-id "${eni_id}" >/dev/null 2>&1
                    fi
                done
                
                # 短時間待機後にサブネット削除を試行
                sleep 15
                log "サブネット ${name} (${SUBNET_ID}) を削除中..."
                
                # 削除試行（最大3回リトライ）
                for retry in {1..3}; do
                    if aws_cmd "${TGW_REGION}" ec2 delete-subnet --subnet-id "${SUBNET_ID}" >/dev/null 2>&1; then
                        log "✅ サブネット ${name} (${SUBNET_ID}) が削除されました。"
                        break
                    else
                        if [ ${retry} -eq 3 ]; then
                            warn "❌ サブネット ${name} (${SUBNET_ID}) の削除に失敗しました。依存関係が残存している可能性があります。"
                        else
                            log "⏳ サブネット削除をリトライします... (${retry}/3)"
                            sleep 30
                        fi
                    fi
                done
            fi
        done
    fi
    v_idx=$((v_idx + 1))
done

step "🎉 スポークアカウントのクリーンアップが完了しました。"

END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED_TIME / 60))
SECONDS=$((ELAPSED_TIME % 60))

log "スクリプト終了: $(date)"
log "総経過時間: ${MINUTES} 分 ${SECONDS} 秒"
