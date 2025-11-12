#!/bin/bash
# スクリプト名: setup_accountA.sh (Hub Account Setup)
# 概要: params.confに基づき、ハブアカウントのTransit Gateway関連リソースを構築する
# 実行方法: ./setup_accountA.sh params.conf

# --- グローバル変数 ---
declare -A TGW_IDS # TGWインデックスをキーとしてTGW IDを格納
declare -A VPC_ATTACHMENT_IDS # VPCインデックスをキーとしてアタッチメントIDを格納
declare -A ALL_VPC_CIDRS # VPCインデックスをキーとしてVPC CIDRを格納

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

    if [ -z "${RESOURCE_ID}" ]; then return; fi
    log "⏳ ${RESOURCE_TYPE} (${RESOURCE_ID}) が '${TARGET_STATE}' になるのを待機中..."
    
    local ELAPSED=0
    while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
        local CURRENT_STATE
        if [ "${RESOURCE_TYPE}" == "transit-gateway" ]; then
            CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --transit-gateway-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
        elif [ "${RESOURCE_TYPE}" == "transit-gateway-attachment" ]; then
            CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
        elif [ "${RESOURCE_TYPE}" == "transit-gateway-peering-attachment" ]; then
            CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-peering-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
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

# TGWの存在確認と作成
function process_tgw() {
    local INDEX=$1
    
    # evalを使って動的に変数を読み込む
    eval "local ACCOUNT_ID_VAR=\${TGW_${INDEX}_ACCOUNT_ID_VAR}"
    eval "local REGION=\${TGW_${INDEX}_REGION}"
    eval "local NAME=\${TGW_${INDEX}_NAME}"
    eval "local ASN=\${TGW_${INDEX}_ASN}"
    eval "local DESCRIPTION=\${TGW_${INDEX}_DESCRIPTION}"
    eval "local ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"

    # 現在のプロファイルが対象アカウントと一致するか確認
    CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ]; then
        log "TGW ${INDEX} (${NAME}) はアカウント ${ACCOUNT_ID} のリソースですが、現在のプロファイルは ${CURRENT_ACCOUNT_ID} です。スキップします。"
        return
    fi

    log "TGW ${INDEX} (${NAME}) in ${REGION} を処理中..."

    TGW_ID=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${NAME}" "Name=state,Values=available,pending" --query 'TransitGateways[0].TransitGatewayId')

    if [ -n "${TGW_ID}" ] && [ "${TGW_ID}" != "None" ]; then
        log "✅ TGW ${NAME} (${TGW_ID}) は既に存在します。"
    else
        log "⏳ TGW ${NAME} を作成中..."
        TGW_ID=$(aws_cmd "${REGION}" ec2 create-transit-gateway \
            --description "${DESCRIPTION}" \
            --options "AmazonSideAsn=${ASN},AutoAcceptSharedAttachments=enable" \
            --tag-specifications "ResourceType=transit-gateway,Tags=[{Key=Name,Value=${NAME}},${TAGS}]" --query 'TransitGateway.TransitGatewayId')
        
        wait_for_state "${REGION}" "transit-gateway" "${TGW_ID}" "available" "TransitGateways[0].State"
        log "✅ TGW ${NAME} (${TGW_ID}) が作成されました。"
    fi
    TGW_IDS[${INDEX}]=${TGW_ID}
}

# VPCアタッチメントの処理
function process_vpc_attachment() {
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
    local TGW_ID=${TGW_IDS[${TGW_INDEX}]}
    if [ -z "${TGW_ID}" ]; then
        warn "VPC ${INDEX} のアタッチ先TGW ${TGW_INDEX} が見つかりません。スキップします。"
        return
    fi

    CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    log "VPC ${INDEX} の処理: 現在アカウント=${CURRENT_ACCOUNT_ID}, 対象アカウント=${ACCOUNT_ID}, RAM共有名=${RAM_SHARE_NAME}"

    # 同一アカウントのアタッチメント処理
    if [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ]; then
        log "VPC ${INDEX} (${VPC_ID}) の同一アカウント内アタッチメントを処理中..."
        
        # サブネットの作成
        read -ra SUBNET_NAMES <<< "${SUBNET_NAMES_STR}"
        read -ra SUBNET_CIDRS <<< "${SUBNET_CIDRS_STR}"
        read -ra SUBNET_AZS <<< "${SUBNET_AZS_STR}"
        local SUBNET_IDS=""
        for i in "${!SUBNET_NAMES[@]}"; do
            SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${SUBNET_NAMES[i]}" --query 'Subnets[0].SubnetId')
            if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" == "None" ]; then
                log "⏳ サブネット ${SUBNET_NAMES[i]} を作成中..."
                SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${SUBNET_CIDRS[i]}" --availability-zone "${SUBNET_AZS[i]}" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${SUBNET_NAMES[i]}},${TAGS}]" --query 'Subnet.SubnetId')
            fi
            SUBNET_IDS+="${SUBNET_ID} "
        done

        # アタッチメントの作成
        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${ATTACHMENT_NAME}" --query 'TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId')
        if [ -z "${ATTACHMENT_ID}" ] || [ "${ATTACHMENT_ID}" == "None" ]; then
            log "⏳ アタッチメント ${ATTACHMENT_NAME} を作成中..."
            ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 create-transit-gateway-vpc-attachment --transit-gateway-id "${TGW_ID}" --vpc-id "${VPC_ID}" --subnet-ids ${SUBNET_IDS} --tag-specifications "ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=${ATTACHMENT_NAME}},${TAGS}]" --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId')
            wait_for_state "${TGW_REGION}" "transit-gateway-attachment" "${ATTACHMENT_ID}" "available" "TransitGatewayVpcAttachments[0].State"
            log "✅ アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) が作成されました。"
        else
            log "✅ アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) は既に存在します。"
        fi
        VPC_ATTACHMENT_IDS[${INDEX}]=${ATTACHMENT_ID}

    # RAM共有の作成 (クロスアカウントの場合)
    elif [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ] && [ -n "${ACCOUNT_ID}" ]; then
        log "VPC ${INDEX} (${VPC_ID}) のためのRAM共有 ${RAM_SHARE_NAME} をアカウント ${ACCOUNT_ID} に対して処理中..."
        TGW_ARN="arn:aws:ec2:${TGW_REGION}:${CURRENT_ACCOUNT_ID}:transit-gateway/${TGW_ID}"
        log "TGW ARN: ${TGW_ARN}"
        
        SHARE_ARN=$(aws_cmd "${TGW_REGION}" ram get-resource-shares --resource-owner SELF --name "${RAM_SHARE_NAME}" --query 'resourceShares[0].resourceShareArn')
        log "既存のSHARE_ARN: ${SHARE_ARN}"
        
        if [ -z "${SHARE_ARN}" ] || [ "${SHARE_ARN}" == "None" ]; then
            log "⏳ RAM共有 ${RAM_SHARE_NAME} を作成中..."
            CREATE_RESULT=$(aws_cmd "${TGW_REGION}" ram create-resource-share --name "${RAM_SHARE_NAME}" --resource-arns "${TGW_ARN}" --principals "${ACCOUNT_ID}" --query 'resourceShare.resourceShareArn')
            log "RAM共有作成結果: ${CREATE_RESULT}"
            log "✅ RAM共有 ${RAM_SHARE_NAME} を作成しました。アカウント ${ACCOUNT_ID} での承認が必要です。"
        else
            log "✅ RAM共有 ${RAM_SHARE_NAME} は既に存在します (ARN: ${SHARE_ARN})。"
            # 既存の共有にプリンシパルとリソースを関連付ける (冪等性のため)
            log "既存の共有にプリンシパルとリソースを関連付け中..."
            aws_cmd "${TGW_REGION}" ram associate-resource-share --resource-share-arn "${SHARE_ARN}" --principals "${ACCOUNT_ID}" >/dev/null 2>&1
            aws_cmd "${TGW_REGION}" ram associate-resource-share --resource-share-arn "${SHARE_ARN}" --resource-arns "${TGW_ARN}" >/dev/null 2>&1
            log "関連付けが完了しました。"
        fi
    elif [ -n "${RAM_SHARE_NAME}" ]; then
        if [ -z "${ACCOUNT_ID}" ]; then
            log "VPC ${INDEX} のアカウントIDが設定されていないため、RAM共有 '${RAM_SHARE_NAME}' の作成をスキップします。"
        elif [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ]; then
            log "VPC ${INDEX} は同一アカウント内のため、RAM共有 '${RAM_SHARE_NAME}' の作成をスキップします。"
        else
            log "VPC ${INDEX} のRAM共有作成条件が満たされていません。"
        fi
    else
        log "VPC ${INDEX} にはRAM共有設定がないため、処理をスキップします。"
    fi
}

# TGWピアリングの処理
function process_peering() {
    local INDEX=$1
    eval "local ENABLED=\${PEERING_${INDEX}_ENABLED}"
    if [ "${ENABLED}" != "true" ]; then return; fi

    eval "local TGW_A_IDX=\${PEERING_${INDEX}_TGW_A_INDEX}"
    eval "local TGW_B_IDX=\${PEERING_${INDEX}_TGW_B_INDEX}"
    eval "local NAME=\${PEERING_${INDEX}_NAME}"

    local TGW_A_ID=${TGW_IDS[${TGW_A_IDX}]}
    local TGW_B_ID=${TGW_IDS[${TGW_B_IDX}]}
    eval "local TGW_A_REGION=\${TGW_${TGW_A_IDX}_REGION}"
    eval "local TGW_B_REGION=\${TGW_${TGW_B_IDX}_REGION}"
    eval "local TGW_A_ACCOUNT_VAR=\${TGW_${TGW_A_IDX}_ACCOUNT_ID_VAR}"
    eval "local TGW_A_ACCOUNT_ID=\${${TGW_A_ACCOUNT_VAR}}"

    if [ -z "${TGW_A_ID}" ] || [ -z "${TGW_B_ID}" ]; then
        warn "ピアリング ${INDEX} のTGWが見つかりません。スキップします。"
        return
    fi
    
    log "ピアリング ${TGW_A_ID} (${TGW_A_REGION}) <-> ${TGW_B_ID} (${TGW_B_REGION}) を処理中..."

    # ピアリングアタッチメントの作成 (A -> B)
    PEERING_A_ID=$(aws_cmd "${TGW_A_REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${TGW_A_ID}" --query "TransitGatewayPeeringAttachments[?AccepterTgwInfo.TransitGatewayId=='${TGW_B_ID}' && (State=='pendingAcceptance' || State=='available' || State=='modifying')].TransitGatewayAttachmentId | [0]")
    
    if [ -z "${PEERING_A_ID}" ] || [ "${PEERING_A_ID}" == "None" ]; then
        log "⏳ ピアリングアタッチメント (${NAME}) を ${TGW_A_REGION} で作成中..."
        PEERING_A_ID=$(aws_cmd "${TGW_A_REGION}" ec2 create-transit-gateway-peering-attachment --transit-gateway-id "${TGW_A_ID}" --peer-transit-gateway-id "${TGW_B_ID}" --peer-region "${TGW_B_REGION}" --peer-account-id "${TGW_A_ACCOUNT_ID}" --tag-specifications "ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=${NAME}},${TAGS}]" --query 'TransitGatewayPeeringAttachment.TransitGatewayAttachmentId')
        
        wait_for_state "${TGW_A_REGION}" "transit-gateway-peering-attachment" "${PEERING_A_ID}" "pendingAcceptance" "TransitGatewayPeeringAttachments[0].State"
    fi

    # ピアリングの承認 (B側)
    PEERING_B_ID=$(aws_cmd "${TGW_B_REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${TGW_B_ID}" --query "TransitGatewayPeeringAttachments[?RequesterTgwInfo.TransitGatewayId=='${TGW_A_ID}' && State=='pendingAcceptance'].TransitGatewayAttachmentId | [0]")
    if [ -n "${PEERING_B_ID}" ] && [ "${PEERING_B_ID}" != "None" ]; then
        log "⏳ ピアリング (${PEERING_B_ID}) を ${TGW_B_REGION} で承認中..."
        aws_cmd "${TGW_B_REGION}" ec2 accept-transit-gateway-peering-attachment --transit-gateway-attachment-id "${PEERING_B_ID}"
    fi
    
    wait_for_state "${TGW_A_REGION}" "transit-gateway-peering-attachment" "${PEERING_A_ID}" "available" "TransitGatewayPeeringAttachments[0].State"
    log "✅ ピアリング ${NAME} が 'available' になりました。"
}

# ルーティング設定
function configure_routing() {
    log "ルーティング設定を開始します..."

    # TGWルートテーブルへの静的ルート追加 (ピアリング経由)
    local p_idx=1
    while eval "test -v PEERING_${p_idx}_ENABLED"; do
        eval "local ENABLED=\${PEERING_${p_idx}_ENABLED}"
        if [ "${ENABLED}" == "true" ]; then
            # TGW A -> TGW B へのルート
            configure_peering_routes_for_tgw "${p_idx}" "A" "B"
            # TGW B -> TGW A へのルート
            configure_peering_routes_for_tgw "${p_idx}" "B" "A"
        fi
        p_idx=$((p_idx + 1))
    done

    # VPCルートテーブルへのルート追加
    local v_idx=1
    while eval "test -v VPC_${v_idx}_ENABLED"; do
        eval "local ENABLED=\${VPC_${v_idx}_ENABLED}"
        if [ "${ENABLED}" == "true" ]; then
            configure_vpc_routes "${v_idx}"
        fi
        v_idx=$((v_idx + 1))
    done
}

function configure_peering_routes_for_tgw() {
    local PEERING_IDX=$1
    local SRC_TGW_SUFFIX=$2 # "A" or "B"
    local DST_TGW_SUFFIX=$3 # "A" or "B"

    eval "local SRC_TGW_IDX=\${PEERING_${PEERING_IDX}_TGW_${SRC_TGW_SUFFIX}_INDEX}"
    eval "local DST_TGW_IDX=\${PEERING_${PEERING_IDX}_TGW_${DST_TGW_SUFFIX}_INDEX}"
    
    local SRC_TGW_ID=${TGW_IDS[${SRC_TGW_IDX}]}
    local DST_TGW_ID=${TGW_IDS[${DST_TGW_IDX}]}
    eval "local SRC_TGW_REGION=\${TGW_${SRC_TGW_IDX}_REGION}"

    local PEERING_ATTACHMENT_ID=$(aws_cmd "${SRC_TGW_REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${SRC_TGW_ID}" --query "TransitGatewayPeeringAttachments[?(AccepterTgwInfo.TransitGatewayId=='${DST_TGW_ID}' || RequesterTgwInfo.TransitGatewayId=='${DST_TGW_ID}') && State=='available'].TransitGatewayAttachmentId | [0]")
    
    if [ -z "${PEERING_ATTACHMENT_ID}" ]; then
        warn "TGW ${SRC_TGW_IDX} -> ${DST_TGW_IDX} のピアリングアタッチメントが見つかりません。"
        return
    fi

    local TGW_RT_ID=$(aws_cmd "${SRC_TGW_REGION}" ec2 describe-transit-gateway-route-tables --filters "Name=transit-gateway-id,Values=${SRC_TGW_ID}" "Name=default-association-route-table,Values=true" --query "TransitGatewayRouteTables[0].TransitGatewayRouteTableId")

    # 宛先TGWに接続されている全てのVPCのCIDRに対してルートを追加
    for vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
        eval "local ATTACH_TGW_IDX=\${VPC_${vpc_idx}_ATTACH_TO_TGW_INDEX}"
        if [ "${ATTACH_TGW_IDX}" == "${DST_TGW_IDX}" ]; then
            local DEST_CIDR=${ALL_VPC_CIDRS[${vpc_idx}]}
            log "TGW RT ${TGW_RT_ID} にルートを追加: ${DEST_CIDR} -> ${PEERING_ATTACHMENT_ID}"
            aws_cmd "${SRC_TGW_REGION}" ec2 create-transit-gateway-route --destination-cidr-block "${DEST_CIDR}" --transit-gateway-attachment-id "${PEERING_ATTACHMENT_ID}" --transit-gateway-route-table-id "${TGW_RT_ID}" >/dev/null 2>&1 || log "ルート ${DEST_CIDR} は既に存在するか、作成に失敗しました。"
        fi
    done
}

function configure_vpc_routes() {
    local VPC_IDX=$1
    eval "local ACCOUNT_ID_VAR=\${VPC_${VPC_IDX}_ACCOUNT_ID_VAR}"
    eval "local ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    
    CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ]; then
        return # 他のアカウントのVPCはここでは処理しない
    fi

    eval "local TGW_IDX=\${VPC_${VPC_IDX}_ATTACH_TO_TGW_INDEX}"
    eval "local RT_IDS_STR=\${VPC_${VPC_IDX}_ROUTE_TABLE_IDS}"
    eval "local TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
    local TGW_ID=${TGW_IDS[${TGW_IDX}]}

    read -ra RT_IDS <<< "${RT_IDS_STR}"
    for rt_id in "${RT_IDS[@]}"; do
        # 他の全てのVPCへのルートを追加
        for other_vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
            if [ "${VPC_IDX}" != "${other_vpc_idx}" ]; then
                local DEST_CIDR=${ALL_VPC_CIDRS[${other_vpc_idx}]}
                log "VPC RT ${rt_id} にルートを追加: ${DEST_CIDR} -> ${TGW_ID}"
                aws_cmd "${TGW_REGION}" ec2 create-route --route-table-id "${rt_id}" --destination-cidr-block "${DEST_CIDR}" --transit-gateway-id "${TGW_ID}" >/dev/null 2>&1 || log "ルート ${DEST_CIDR} は既に存在するか、作成に失敗しました。"
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

step "1. 全VPCのCIDR情報を収集"
i=1
while eval "test -v VPC_${i}_ENABLED"; do
    eval "ENABLED=\${VPC_${i}_ENABLED}"
    if [ "${ENABLED}" == "true" ]; then
        eval "CIDR=\${VPC_${i}_VPC_CIDR}"
        ALL_VPC_CIDRS[${i}]=${CIDR}
        log "VPC ${i} のCIDR: ${CIDR} を収集しました。"
    fi
    i=$((i + 1))
done

step "2. TGWの作成"
j=1
while eval "test -v TGW_${j}_REGION"; do
    process_tgw $j
    j=$((j + 1))
done

step "3. VPCアタッチメントとRAM共有の作成"
k=1
while eval "test -v VPC_${k}_ENABLED"; do
    process_vpc_attachment $k
    k=$((k + 1))
done

step "4. TGWピアリングの作成と承認"
l=1
while eval "test -v PEERING_${l}_ENABLED"; do
    process_peering $l
    l=$((l + 1))
done

step "5. ルーティングの設定"
configure_routing

step "🎉 ハブアカウントの設定が完了しました。"
log "クロスアカウントVPCがある場合は、次にスポークアカウント用のスクリプトを実行してください。"

END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED_TIME / 60))
SECONDS=$((ELAPSED_TIME % 60))

log "スクリプト終了: $(date)"
log "総経過時間: ${MINUTES} 分 ${SECONDS} 秒"
