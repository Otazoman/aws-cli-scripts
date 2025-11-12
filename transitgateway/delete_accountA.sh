#!/bin/bash
# スクリプト名: delete_accountA.sh (Hub Account Cleanup)
# 概要: params.confに基づき、ハブアカウントのTransit Gateway関連リソースを削除する
# 実行方法: ./delete_accountA.sh params.conf

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
wait_for_resource_deleted() {
    local REGION=$1
    local RESOURCE_TYPE=$2 # e.g., transit-gateway, transit-gateway-attachment
    local RESOURCE_ID=$3
    local MAX_WAIT=300
    local INTERVAL=15

    if [ -z "${RESOURCE_ID}" ]; then return; fi
    log "⏳ ${RESOURCE_TYPE} (${RESOURCE_ID}) が完全に削除されるのを待機中..."
    
    # aws ec2 wait ...-deleted は存在しないため、カスタムポーリングで実装
    local ELAPSED=0
    while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
        local STATE
        if [ "${RESOURCE_TYPE}" == "transit-gateway" ]; then
            STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --transit-gateway-ids "${RESOURCE_ID}" --query 'TransitGateways[0].State' 2>/dev/null)
        elif [ "${RESOURCE_TYPE}" == "transit-gateway-attachment" ]; then
            STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query 'TransitGatewayVpcAttachments[0].State' 2>/dev/null)
        elif [ "${RESOURCE_TYPE}" == "transit-gateway-peering-attachment" ]; then
             STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-peering-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query 'TransitGatewayPeeringAttachments[0].State' 2>/dev/null)
        fi

        if [ -z "${STATE}" ] || [ "${STATE}" == "deleted" ]; then
            log "✅ ${RESOURCE_TYPE} (${RESOURCE_ID}) は削除されました。"
            return 0
        fi
        sleep ${INTERVAL}
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    warn "❌ ${RESOURCE_TYPE} (${RESOURCE_ID}) の削除待機がタイムアウトしました。現在の状態: ${STATE}"
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

step "1. ルーティングの削除"
# VPCルートテーブルからのルート削除
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

# TGW静的ルートの削除
p_idx=1
while eval "test -v PEERING_${p_idx}_ENABLED"; do
    eval "ENABLED=\${PEERING_${p_idx}_ENABLED}"
    if [ "${ENABLED}" == "true" ]; then
        # TGW A -> TGW B へのルートを削除
        eval "TGW_A_IDX=\${PEERING_${p_idx}_TGW_A_INDEX}"
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
                    log "TGW RT ${TGW_RT_ID} から静的ルート ${DEST_CIDR} を削除中..."
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
                    log "TGW RT ${TGW_RT_ID} から静的ルート ${DEST_CIDR} を削除中..."
                    aws_cmd "${TGW_B_REGION}" ec2 delete-transit-gateway-route --destination-cidr-block "${DEST_CIDR}" --transit-gateway-route-table-id "${TGW_RT_ID}" >/dev/null 2>&1
                fi
            done
        fi
    fi
    p_idx=$((p_idx + 1))
done

step "2. RAM共有の削除"
v_idx=1
while eval "test -v VPC_${v_idx}_ENABLED"; do
    eval "ENABLED=\${VPC_${v_idx}_ENABLED}"
    eval "RAM_SHARE_NAME=\${VPC_${v_idx}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
    eval "ACCOUNT_ID_VAR=\${VPC_${v_idx}_ACCOUNT_ID_VAR}"
    eval "SPOKE_ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    eval "TGW_IDX=\${VPC_${v_idx}_ATTACH_TO_TGW_INDEX}"
    eval "TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
    eval "TGW_NAME=\${TGW_${TGW_IDX}_NAME}"

    if [ "${ENABLED}" == "true" ] && [ -n "${RAM_SHARE_NAME}" ]; then
        TGW_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${TGW_NAME}" --query 'TransitGateways[0].TransitGatewayId')
        SHARE_ARN=$(aws_cmd "${TGW_REGION}" ram get-resource-shares --resource-owner SELF --name "${RAM_SHARE_NAME}" --query 'resourceShares[0].resourceShareArn')
        if [ -n "${SHARE_ARN}" ]; then
            log "RAM共有 ${RAM_SHARE_NAME} を削除中..."
            TGW_ARN="arn:aws:ec2:${TGW_REGION}:${CURRENT_ACCOUNT_ID}:transit-gateway/${TGW_ID}"
            aws_cmd "${TGW_REGION}" ram disassociate-resource-share --resource-share-arn "${SHARE_ARN}" --resource-arns "${TGW_ARN}" --principals "${SPOKE_ACCOUNT_ID}" >/dev/null 2>&1
            aws_cmd "${TGW_REGION}" ram delete-resource-share --resource-share-arn "${SHARE_ARN}"
        fi
    fi
    v_idx=$((v_idx + 1))
done

step "3. 全アタッチメントの削除"
log "全TGWからピアリングアタッチメントとVPCアタッチメントを削除します..."

t_idx=1
while eval "test -v TGW_${t_idx}_REGION"; do
    eval "ACCOUNT_ID_VAR=\${TGW_${t_idx}_ACCOUNT_ID_VAR}"
    eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    if [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
        eval "REGION=\${TGW_${t_idx}_REGION}"
        eval "NAME=\${TGW_${t_idx}_NAME}"
        TGW_ID=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${NAME}" --query "TransitGateways[?State!='deleted'].TransitGatewayId | [0]")
        if [ -n "${TGW_ID}" ] && [ "${TGW_ID}" != "None" ]; then
            log "TGW ${NAME} (${TGW_ID}) の全アタッチメントを削除中..."
            
            # VPCアタッチメントを削除
            VPC_ATTACHMENTS=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${TGW_ID}" --query "TransitGatewayVpcAttachments[?State!='deleted'].TransitGatewayAttachmentId" | tr '\t' ' ')
            for attachment_id in ${VPC_ATTACHMENTS}; do
                if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
                    log "VPCアタッチメント ${attachment_id} を削除中..."
                    aws_cmd "${REGION}" ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id "${attachment_id}"
                    wait_for_resource_deleted "${REGION}" "transit-gateway-attachment" "${attachment_id}"
                fi
            done
            
            # ピアリングアタッチメントを削除
            PEERING_ATTACHMENTS=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${TGW_ID}" --query "TransitGatewayPeeringAttachments[?State!='deleted'].TransitGatewayAttachmentId" | tr '\t' ' ')
            for attachment_id in ${PEERING_ATTACHMENTS}; do
                if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
                    log "ピアリングアタッチメント ${attachment_id} を削除中..."
                    aws_cmd "${REGION}" ec2 delete-transit-gateway-peering-attachment --transit-gateway-attachment-id "${attachment_id}"
                    wait_for_resource_deleted "${REGION}" "transit-gateway-peering-attachment" "${attachment_id}"
                fi
            done
        fi
    fi
    t_idx=$((t_idx + 1))
done

step "4. TGW本体の削除"
t_idx=1
while eval "test -v TGW_${t_idx}_REGION"; do
    eval "ACCOUNT_ID_VAR=\${TGW_${t_idx}_ACCOUNT_ID_VAR}"
    eval "ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    if [ "${ACCOUNT_ID}" == "${CURRENT_ACCOUNT_ID}" ]; then
        eval "REGION=\${TGW_${t_idx}_REGION}"
        eval "NAME=\${TGW_${t_idx}_NAME}"
        TGW_ID=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${NAME}" --query "TransitGateways[?State!='deleted'].TransitGatewayId | [0]")
        if [ -n "${TGW_ID}" ] && [ "${TGW_ID}" != "None" ]; then
            log "TGW ${NAME} (${TGW_ID}) を削除中..."
            aws_cmd "${REGION}" ec2 delete-transit-gateway --transit-gateway-id "${TGW_ID}"
            wait_for_resource_deleted "${REGION}" "transit-gateway" "${TGW_ID}"
        fi
    fi
    t_idx=$((t_idx + 1))
done

step "5. ENI用サブネットの削除"
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
                log "サブネット ${name} (${SUBNET_ID}) の依存関係を確認中..."
                
                # サブネット内のENIを削除
                ENI_IDS=$(aws_cmd "${TGW_REGION}" ec2 describe-network-interfaces --filters "Name=subnet-id,Values=${SUBNET_ID}" --query "NetworkInterfaces[?Status!='available'].NetworkInterfaceId" | tr '\t' ' ')
                for eni_id in ${ENI_IDS}; do
                    if [ -n "${eni_id}" ] && [ "${eni_id}" != "None" ]; then
                        log "ENI ${eni_id} をデタッチ中..."
                        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-network-interfaces --network-interface-ids "${eni_id}" --query 'NetworkInterfaces[0].Attachment.AttachmentId')
                        if [ -n "${ATTACHMENT_ID}" ] && [ "${ATTACHMENT_ID}" != "None" ]; then
                            aws_cmd "${TGW_REGION}" ec2 detach-network-interface --attachment-id "${ATTACHMENT_ID}" >/dev/null 2>&1
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

step "🎉 ハブアカウントのクリーンアップが完了しました。"

END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED_TIME / 60))
SECONDS=$((ELAPSED_TIME % 60))

log "スクリプト終了: $(date)"
log "総経過時間: ${MINUTES} 分 ${SECONDS} 秒"
