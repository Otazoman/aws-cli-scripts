#!/bin/bash
# スクリプト名: setup.sh (Unified Hub/Spoke Setup)
# 概要: params.confに基づき、現在のAWSアカウントの役割（ハブまたはスポーク）を自動的に判断し、
#       Transit Gateway関連リソースの構築または設定を行う。
# 実行方法: ./setup.sh params.conf

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
    log "${RESOURCE_TYPE} (${RESOURCE_ID}) が '${TARGET_STATE}' になるのを待機中..."
    
    local ELAPSED=0
    while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
        local CURRENT_STATE
        case "${RESOURCE_TYPE}" in
            "transit-gateway")
                CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --transit-gateway-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
                ;;
            "transit-gateway-attachment" | "transit-gateway-vpc-attachment")
                CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
                ;;
            "transit-gateway-peering-attachment")
                CURRENT_STATE=$(aws_cmd "${REGION}" ec2 describe-transit-gateway-peering-attachments --transit-gateway-attachment-ids "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
                ;;
            "ram-share")
                # RESOURCE_ID for ram-share is the RAM Share Name
                CURRENT_STATE=$(aws_cmd "${REGION}" ram get-resource-shares --resource-owner OTHER-ACCOUNTS --name "${RESOURCE_ID}" --query "${QUERY}" 2>/dev/null)
                ;;
        esac

        if [ "${CURRENT_STATE}" == "${TARGET_STATE}" ]; then
            log "${RESOURCE_TYPE} (${RESOURCE_ID}) は '${TARGET_STATE}' 状態になりました。"
            return 0
        fi
        sleep ${INTERVAL}
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    error "${RESOURCE_TYPE} (${RESOURCE_ID}) の状態待機がタイムアウトしました。現在の状態: ${CURRENT_STATE}"
}

# TGWの存在確認と作成 (ハブアカウントでのみ実行)
function process_tgw() {
    local INDEX=$1
    
    eval "local ACCOUNT_ID_VAR=\${TGW_${INDEX}_ACCOUNT_ID_VAR}"
    eval "local REGION=\${TGW_${INDEX}_REGION}"
    eval "local NAME=\${TGW_${INDEX}_NAME}"
    eval "local ASN=\${TGW_${INDEX}_ASN}"
    eval "local DESCRIPTION=\${TGW_${INDEX}_DESCRIPTION}"
    eval "local ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"

    # 現在のプロファイルが対象アカウントと一致するか確認
    if [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ]; then
        return
    fi

    log "HUB: TGW ${INDEX} (${NAME}) in ${REGION} を処理中..."

    TGW_ID=$(aws_cmd "${REGION}" ec2 describe-transit-gateways --filters "Name=tag:Name,Values=${NAME}" "Name=state,Values=available,pending" --query 'TransitGateways[0].TransitGatewayId')

    if [ -n "${TGW_ID}" ] && [ "${TGW_ID}" != "None" ]; then
        log "TGW ${NAME} (${TGW_ID}) は既に存在します。"
    else
        log "TGW ${NAME} を作成中..."
        TGW_ID=$(aws_cmd "${REGION}" ec2 create-transit-gateway \
            --description "${DESCRIPTION}" \
            --options "AmazonSideAsn=${ASN},AutoAcceptSharedAttachments=enable" \
            --tag-specifications "ResourceType=transit-gateway,Tags=[{Key=Name,Value=${NAME}},${TAGS}]" --query 'TransitGateway.TransitGatewayId')
        
        wait_for_state "${REGION}" "transit-gateway" "${TGW_ID}" "available" "TransitGateways[0].State"
        log "TGW ${NAME} (${TGW_ID}) が作成されました。"
    fi
    TGW_IDS[${INDEX}]=${TGW_ID}
}

# VPCアタッチメントの処理 (ハブ・スポーク共通ロジック)
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

    log "VPC ${INDEX} の処理: 現在アカウント=${CURRENT_ACCOUNT_ID}, 対象アカウント=${ACCOUNT_ID}, RAM共有名=${RAM_SHARE_NAME}"

    # TGW_IDが空でもRAM共有設定があるスポークVPCの場合は処理を続行
    if [ -z "${TGW_ID}" ]; then
        # 現在のアカウントがVPCのアカウントと一致し、RAM共有設定がある場合はスポーク処理
        if [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ]; then
            log "SPOKE: VPC ${INDEX} のスポーク処理を開始します（TGWは共有リソースから検索）..."
            process_spoke_vpc_attachment "${INDEX}"
            return
        else
            warn "VPC ${INDEX} のアタッチ先TGW ${TGW_INDEX} が見つかりません。スキップします。"
            return
        fi
    fi

    # 同一アカウントのアタッチメント処理
    if [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ]; then
        log "VPC ${INDEX} (${VPC_ID}) の同一アカウント内アタッチメントを処理中..."
        process_hub_vpc_attachment "${INDEX}"

    # RAM共有の作成 (クロスアカウントの場合)
    elif [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ] && [ -n "${ACCOUNT_ID}" ]; then
        log "VPC ${INDEX} (${VPC_ID}) のためのRAM共有 ${RAM_SHARE_NAME} をアカウント ${ACCOUNT_ID} に対して処理中..."
        TGW_ARN="arn:aws:ec2:${TGW_REGION}:${CURRENT_ACCOUNT_ID}:transit-gateway/${TGW_ID}"
        log "TGW ARN: ${TGW_ARN}"
        
        # RAM共有の状態を含めて確認（削除済みの共有は除外）
        SHARE_INFO=$(aws_cmd "${TGW_REGION}" ram get-resource-shares --resource-owner SELF --name "${RAM_SHARE_NAME}" --query "resourceShares[?status=='ACTIVE' || status=='PENDING'][0].[resourceShareArn,status]")
        SHARE_ARN=$(echo "${SHARE_INFO}" | cut -f1)
        SHARE_STATUS=$(echo "${SHARE_INFO}" | cut -f2)

        log "既存のRAM共有確認: ARN=${SHARE_ARN}, STATUS=${SHARE_STATUS}"

        if [ -z "${SHARE_ARN}" ] || [ "${SHARE_ARN}" == "None" ]; then
            log "RAM共有 ${RAM_SHARE_NAME} を作成中..."
            SHARE_ARN=$(aws_cmd "${TGW_REGION}" ram create-resource-share --name "${RAM_SHARE_NAME}" --resource-arns "${TGW_ARN}" --principals "${ACCOUNT_ID}" --query 'resourceShare.resourceShareArn')
            log "RAM共有 ${RAM_SHARE_NAME} (ARN: ${SHARE_ARN}) を作成しました。アカウント ${ACCOUNT_ID} での承認が必要です。"
        else
            log "RAM共有 ${RAM_SHARE_NAME} は既に存在します (ARN: ${SHARE_ARN}, STATUS: ${SHARE_STATUS})。"
            # 既存の共有にプリンシパルとリソースを関連付ける (冪等性のため)
            log "既存の共有にプリンシパルとリソースを関連付け中..."
            aws_cmd "${TGW_REGION}" ram associate-resource-share --resource-share-arn "${SHARE_ARN}" --principals "${ACCOUNT_ID}" --resource-arns "${TGW_ARN}" >/dev/null 2>&1
            log "関連付けが完了しました。"
        fi
    # このelifブロックは先行するif条件のカバレッジにより、ACCOUNT_IDが空の場合のみに限定される
    elif [ -n "${RAM_SHARE_NAME}" ] && [ -z "${ACCOUNT_ID}" ]; then
        log "VPC ${INDEX} のアカウントIDが設定されていないため、RAM共有 '${RAM_SHARE_NAME}' の作成をスキップします。"
    else
        log "VPC ${INDEX} にはRAM共有設定がないため、クロスアカウント処理をスキップします。"
    fi
    
    # 現在のアカウントがVPCのアカウントと一致しない場合は処理終了（RAM共有のみ作成済み）
    if [ "${CURRENT_ACCOUNT_ID}" != "${ACCOUNT_ID}" ]; then
        return
    fi
    
    # 現在のアカウントがVPCのアカウントと一致する場合の処理
    # RAM共有設定があるVPCの場合はスポーク処理、なければハブ処理済み
    if [ -n "${RAM_SHARE_NAME}" ]; then
        log "SPOKE: VPC ${INDEX} のスポークアカウント処理を開始します..."
        process_spoke_vpc_attachment "${INDEX}"
    fi
}

# RAM共有の作成 (ハブアカウントの役割)
function process_ram_share_creation_for_vpc() {
    local INDEX=$1
    eval "local RAM_SHARE_NAME=\${VPC_${INDEX}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
    eval "local SPOKE_ACCOUNT_ID_VAR=\${VPC_${INDEX}_ACCOUNT_ID_VAR}"
    eval "local SPOKE_ACCOUNT_ID=\${${SPOKE_ACCOUNT_ID_VAR}}"
    eval "local TGW_INDEX=\${VPC_${INDEX}_ATTACH_TO_TGW_INDEX}"
    eval "local HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_INDEX}_ACCOUNT_ID_VAR}"
    eval "local HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"
    eval "local TGW_REGION=\${TGW_${TGW_INDEX}_REGION}"
    local TGW_ID=${TGW_IDS[${TGW_INDEX}]}

    # 現在がハブアカウントで、VPCが別アカウントで、RAM共有が設定されている場合のみ実行
    if [ "${CURRENT_ACCOUNT_ID}" == "${HUB_ACCOUNT_ID}" ] && [ "${CURRENT_ACCOUNT_ID}" != "${SPOKE_ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ]; then
        if [ -z "${TGW_ID}" ]; then
            warn "RAM共有作成スキップ: VPC ${INDEX} のアタッチ先TGW ${TGW_INDEX} が見つかりません。"
            return
        fi

        log "HUB: VPC ${INDEX} のためのRAM共有 ${RAM_SHARE_NAME} をアカウント ${SPOKE_ACCOUNT_ID} に対して処理中..."
        TGW_ARN="arn:aws:ec2:${TGW_REGION}:${CURRENT_ACCOUNT_ID}:transit-gateway/${TGW_ID}"
        
        SHARE_ARN=$(aws_cmd "${TGW_REGION}" ram get-resource-shares --resource-owner SELF --name "${RAM_SHARE_NAME}" --query "resourceShares[0].resourceShareArn")
        
        if [ -z "${SHARE_ARN}" ] || [ "${SHARE_ARN}" == "None" ]; then
            log "RAM共有 ${RAM_SHARE_NAME} を作成中..."
            aws_cmd "${TGW_REGION}" ram create-resource-share --name "${RAM_SHARE_NAME}" --resource-arns "${TGW_ARN}" --principals "${SPOKE_ACCOUNT_ID}"
            log "RAM共有 ${RAM_SHARE_NAME} を作成しました。アカウント ${SPOKE_ACCOUNT_ID} での承認が必要です。"
        else
            log "RAM共有 ${RAM_SHARE_NAME} (ARN: ${SHARE_ARN}) は既に存在します。プリンシパルとリソースを関連付けます..."
            aws_cmd "${TGW_REGION}" ram associate-resource-share --resource-share-arn "${SHARE_ARN}" --principals "${SPOKE_ACCOUNT_ID}" --resource-arns "${TGW_ARN}" >/dev/null 2>&1
        fi
    fi
}

# 同一アカウントVPCアタッチメント (ハブアカウントの役割)
function process_hub_vpc_attachment() {
    local INDEX=$1
    eval "local VPC_ID=\${VPC_${INDEX}_VPC_ID}"
    eval "local ATTACHMENT_NAME=\${VPC_${INDEX}_ATTACHMENT_NAME}"
    eval "local TGW_INDEX=\${VPC_${INDEX}_ATTACH_TO_TGW_INDEX}"
    eval "local TGW_REGION=\${TGW_${TGW_INDEX}_REGION}"
    eval "local SUBNET_NAMES_STR=\${VPC_${INDEX}_ENI_SUBNET_NAMES}"
    eval "local SUBNET_CIDRS_STR=\${VPC_${INDEX}_ENI_SUBNET_CIDRS}"
    eval "local SUBNET_AZS_STR=\${VPC_${INDEX}_ENI_SUBNET_AZS}"
    local TGW_ID=${TGW_IDS[${TGW_INDEX}]}

    if [ -z "${TGW_ID}" ]; then warn "ハブVPC ${INDEX} のアタッチ先TGWが見つかりません。" ; return; fi
        
    # サブネット作成
    read -ra SUBNET_NAMES <<< "${SUBNET_NAMES_STR}"
    read -ra SUBNET_CIDRS <<< "${SUBNET_CIDRS_STR}"
    read -ra SUBNET_AZS <<< "${SUBNET_AZS_STR}"
    local SUBNET_IDS=""
    for i in "${!SUBNET_NAMES[@]}"; do
        SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${SUBNET_NAMES[i]}" --query 'Subnets[0].SubnetId')
        if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" == "None" ]; then
            log "サブネット ${SUBNET_NAMES[i]} を作成中..."
            SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${SUBNET_CIDRS[i]}" --availability-zone "${SUBNET_AZS[i]}" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${SUBNET_NAMES[i]}},${TAGS}]" --query 'Subnet.SubnetId')
        fi
        SUBNET_IDS+="${SUBNET_ID} "
    done

    # アタッチメント作成
    ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${ATTACHMENT_NAME}" --query 'TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId')
    if [ -z "${ATTACHMENT_ID}" ] || [ "${ATTACHMENT_ID}" == "None" ]; then
        log "アタッチメント ${ATTACHMENT_NAME} を作成中..."
        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 create-transit-gateway-vpc-attachment --transit-gateway-id "${TGW_ID}" --vpc-id "${VPC_ID}" --subnet-ids ${SUBNET_IDS} --tag-specifications "ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=${ATTACHMENT_NAME}},${TAGS}]" --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId')
        wait_for_state "${TGW_REGION}" "transit-gateway-attachment" "${ATTACHMENT_ID}" "available" "TransitGatewayVpcAttachments[0].State"
    else
        log "アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) は既に存在します。"
    fi
    VPC_ATTACHMENT_IDS[${INDEX}]=${ATTACHMENT_ID}
}

# スポークVPCアタッチメント (スポークアカウントの役割)
function process_spoke_vpc_attachment() {
    local INDEX=$1
    eval "local VPC_ID=\${VPC_${INDEX}_VPC_ID}"
    eval "local ATTACHMENT_NAME=\${VPC_${INDEX}_ATTACHMENT_NAME}"
    eval "local RAM_SHARE_NAME=\${VPC_${INDEX}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
    eval "local TGW_INDEX=\${VPC_${INDEX}_ATTACH_TO_TGW_INDEX}"
    eval "local TGW_REGION=\${TGW_${TGW_INDEX}_REGION}"
    eval "local TGW_NAME=\${TGW_${TGW_INDEX}_NAME}"
    eval "local HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_INDEX}_ACCOUNT_ID_VAR}"
    eval "local HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"
    eval "local SUBNET_NAMES_STR=\${VPC_${INDEX}_ENI_SUBNET_NAMES}"
    eval "local SUBNET_CIDRS_STR=\${VPC_${INDEX}_ENI_SUBNET_CIDRS}"
    eval "local SUBNET_AZS_STR=\${VPC_${INDEX}_ENI_SUBNET_AZS}"

    log "SPOKE: VPC ${INDEX} (${VPC_ID}) in ${TGW_REGION} のアタッチメント処理を開始"

    # 1. RAM共有の承認（詳細な確認とフォールバック付き）
    log "RAM共有 '${RAM_SHARE_NAME}' の招待を検索・承認します..."
    INVITATION_ARN=$(aws_cmd "${TGW_REGION}" ram get-resource-share-invitations --query "resourceShareInvitations[?resourceShareName=='${RAM_SHARE_NAME}' && status=='PENDING'].resourceShareInvitationArn | [0]")
    
    if [ -n "${INVITATION_ARN}" ] && [ "${INVITATION_ARN}" != "None" ]; then
        log "PENDING状態の招待 (${INVITATION_ARN}) を承認します..."
        aws_cmd "${TGW_REGION}" ram accept-resource-share-invitation --resource-share-invitation-arn "${INVITATION_ARN}"
        
        # 共有がACTIVEになるのを汎用待機関数で待つ
        local query="resourceShares[?name=='${RAM_SHARE_NAME}'].status | [0]"
        wait_for_state "${TGW_REGION}" "ram-share" "${RAM_SHARE_NAME}" "ACTIVE" "${query}"
    else
        log "PENDING状態の招待は見つかりませんでした。"
    fi

    # 2. 共有されたTGWのIDを取得（複数の方法でフォールバック）
    log "TGW検索条件: HUB_ACCOUNT_ID=${HUB_ACCOUNT_ID}, TGW_NAME=${TGW_NAME}, TGW_REGION=${TGW_REGION}"
    
    # 2. 共有されたTGWのIDを取得（より信頼性の高い方法で）
    # `get-resource-shares` を使用して、指定された名前と所有者(ハブアカウント)から共有リソースのARNを特定する
    log "共有されているTGWリソースを検索中 (Owner: ${HUB_ACCOUNT_ID}, Name: ${RAM_SHARE_NAME})..."
    SHARED_TGW_ARN=$(aws_cmd "${TGW_REGION}" ram list-resources --resource-owner OTHER-ACCOUNTS --resource-share-arns \
        "$(aws_cmd "${TGW_REGION}" ram get-resource-shares --name "${RAM_SHARE_NAME}" --resource-owner OTHER-ACCOUNTS --query "resourceShares[?status=='ACTIVE'].resourceShareArn | [0]")" \
        --resource-type "ec2:TransitGateway" --query "resources[0].arn" 2>/dev/null)
    
    log "検出された共有TGWリソースARN: ${SHARED_TGW_ARN}"

    local SHARED_TGW_ID=""
    if [ -n "${SHARED_TGW_ARN}" ] && [ "${SHARED_TGW_ARN}" != "None" ]; then
        # ARNからTGW IDを抽出 (例: arn:aws:ec2:ap-northeast-1:123456789012:transit-gateway/tgw-0123456789abcdef0)
        SHARED_TGW_ID=$(echo "${SHARED_TGW_ARN}" | awk -F'/' '{print $2}')
        log "共有リソースARNから抽出したTGW ID: ${SHARED_TGW_ID}"
    fi
    
    # フォールバック: Owner IDとNameタグでTGWを直接検索
    if [ -z "${SHARED_TGW_ID}" ] || [ "${SHARED_TGW_ID}" == "None" ]; then
        log "フォールバック: Owner ID (${HUB_ACCOUNT_ID}) と TGW Name (${TGW_NAME}) でTGWを直接検索..."
        SHARED_TGW_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=owner-id,Values=${HUB_ACCOUNT_ID}" "Name=tag:Name,Values=${TGW_NAME}" "Name=state,Values=available" --query 'TransitGateways[0].TransitGatewayId' 2>/dev/null)
        log "Owner IDとNameタグでの検索結果: ${SHARED_TGW_ID}"
    fi
    
    # 最終確認
    if [ -n "${SHARED_TGW_ID}" ] && [ "${SHARED_TGW_ID}" != "None" ]; then
        log "共有されたTGW ID: ${SHARED_TGW_ID} を検出しました。"
        TGW_DETAILS=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --transit-gateway-ids "${SHARED_TGW_ID}" --query 'TransitGateways[0].[TransitGatewayId,State,OwnerId,Description]' 2>/dev/null || echo "")
        log "検出されたTGWの詳細:\n${TGW_DETAILS}"
    else
        error "共有されたTGW IDを検出できませんでした。RAM共有が承認済みで、TGW Name (${TGW_NAME}) が正しいか確認してください。"
    fi

    # 3. TGW用サブネットの作成
    read -ra SUBNET_NAMES <<< "${SUBNET_NAMES_STR}"
    read -ra SUBNET_CIDRS <<< "${SUBNET_CIDRS_STR}"
    read -ra SUBNET_AZS <<< "${SUBNET_AZS_STR}"
    local SUBNET_IDS=""
    for subnet_idx in "${!SUBNET_NAMES[@]}"; do
        SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${SUBNET_NAMES[subnet_idx]}" --query 'Subnets[0].SubnetId')
        if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" == "None" ]; then
            log "サブネット ${SUBNET_NAMES[subnet_idx]} を作成中..."
            SUBNET_ID=$(aws_cmd "${TGW_REGION}" ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${SUBNET_CIDRS[subnet_idx]}" --availability-zone "${SUBNET_AZS[subnet_idx]}" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${SUBNET_NAMES[subnet_idx]}},${TAGS}]" --query 'Subnet.SubnetId')
            if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" == "None" ]; then
                error "サブネット ${SUBNET_NAMES[subnet_idx]} の作成に失敗しました。"
            fi
        fi
        SUBNET_IDS+="${SUBNET_ID} "
    done

    # 4. TGWアタッチメントの作成
    log "VPCアタッチメントを検索中: TGW=${SHARED_TGW_ID}, VPC=${VPC_ID}, NAME=${ATTACHMENT_NAME}"
    
    # より詳細なNameタグでの検索を先に実行
    ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${SHARED_TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${ATTACHMENT_NAME}" --query "TransitGatewayVpcAttachments[?State!='deleted' && State!='deleting'].TransitGatewayAttachmentId | [0]")

    # バックアップとしてNameタグなしで検索
    if [ -z "${ATTACHMENT_ID}" ] || [ "${ATTACHMENT_ID}" == "None" ]; then
        log "Nameタグ付きのアタッチメントが見つからないため、タグなしで再検索します。"
        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --filters "Name=transit-gateway-id,Values=${SHARED_TGW_ID}" "Name=vpc-id,Values=${VPC_ID}" --query "TransitGatewayVpcAttachments[?State!='deleted' && State!='deleting'].TransitGatewayAttachmentId | [0]")
    fi
    
    log "アタッチメント検索結果: ${ATTACHMENT_ID}"
    
    if [ -z "${ATTACHMENT_ID}" ] || [ "${ATTACHMENT_ID}" == "None" ]; then
        log "アタッチメント ${ATTACHMENT_NAME} を作成中..."
        ATTACHMENT_ID=$(aws_cmd "${TGW_REGION}" ec2 create-transit-gateway-vpc-attachment --transit-gateway-id "${SHARED_TGW_ID}" --vpc-id "${VPC_ID}" --subnet-ids ${SUBNET_IDS} --tag-specifications "ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=${ATTACHMENT_NAME}},${TAGS}]" --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId')
        wait_for_state "${TGW_REGION}" "transit-gateway-attachment" "${ATTACHMENT_ID}" "available" "TransitGatewayVpcAttachments[0].State"
        log "アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) が作成されました。"
    else
        # 既存アタッチメントの状態を確認
        EXISTING_STATE=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "${ATTACHMENT_ID}" --query 'TransitGatewayVpcAttachments[0].State' 2>/dev/null)
        log "アタッチメント ${ATTACHMENT_NAME} (${ATTACHMENT_ID}) は既に存在します。状態: ${EXISTING_STATE}"
    fi
    VPC_ATTACHMENT_IDS[${INDEX}]=${ATTACHMENT_ID}
}

# TGWピアリングの処理 (ハブアカウントでのみ実行)
function process_peering() {
    local INDEX=$1
    eval "local ENABLED=\${PEERING_${INDEX}_ENABLED}"
    if [ "${ENABLED}" != "true" ]; then return; fi

    eval "local TGW_A_IDX=\${PEERING_${INDEX}_TGW_A_INDEX}"
    eval "local TGW_B_IDX=\${PEERING_${INDEX}_TGW_B_INDEX}"
    eval "local NAME=\${PEERING_${INDEX}_NAME}"
    eval "local TGW_A_ACCOUNT_VAR=\${TGW_${TGW_A_IDX}_ACCOUNT_ID_VAR}"
    eval "local TGW_A_ACCOUNT_ID=\${${TGW_A_ACCOUNT_VAR}}"
    eval "local TGW_B_ACCOUNT_VAR=\${TGW_${TGW_B_IDX}_ACCOUNT_ID_VAR}"
    eval "local TGW_B_ACCOUNT_ID=\${${TGW_B_ACCOUNT_VAR}}"
    
    # このピアリングが現在のハブアカウントに関連しているか確認
    if [ "${CURRENT_ACCOUNT_ID}" != "${TGW_A_ACCOUNT_ID}" ]; then
        return
    fi

    local TGW_A_ID=${TGW_IDS[${TGW_A_IDX}]}
    local TGW_B_ID=${TGW_IDS[${TGW_B_IDX}]}
    eval "local TGW_A_REGION=\${TGW_${TGW_A_IDX}_REGION}"
    eval "local TGW_B_REGION=\${TGW_${TGW_B_IDX}_REGION}"

    if [ -z "${TGW_A_ID}" ] || [ -z "${TGW_B_ID}" ]; then warn "ピアリング ${INDEX} のTGWが見つかりません。" ; return; fi
    
    log "HUB: ピアリング ${TGW_A_ID} (${TGW_A_REGION}) <-> ${TGW_B_ID} (${TGW_B_REGION}) を処理中..."

    # ピアリングアタッチメントの作成 (A -> B)
    PEERING_A_ID=$(aws_cmd "${TGW_A_REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${TGW_A_ID}" --query "TransitGatewayPeeringAttachments[?AccepterTgwInfo.TransitGatewayId=='${TGW_B_ID}' && (State=='pendingAcceptance' || State=='available' || State=='modifying')].TransitGatewayAttachmentId | [0]")
    
    if [ -z "${PEERING_A_ID}" ] || [ "${PEERING_A_ID}" == "None" ]; then
        log "ピアリングアタッチメント (${NAME}) を ${TGW_A_REGION} で作成中..."
        PEERING_A_ID=$(aws_cmd "${TGW_A_REGION}" ec2 create-transit-gateway-peering-attachment --transit-gateway-id "${TGW_A_ID}" --peer-transit-gateway-id "${TGW_B_ID}" --peer-region "${TGW_B_REGION}" --peer-account-id "${TGW_B_ACCOUNT_ID}" --tag-specifications "ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=${NAME}},${TAGS}]" --query 'TransitGatewayPeeringAttachment.TransitGatewayAttachmentId')
        wait_for_state "${TGW_A_REGION}" "transit-gateway-peering-attachment" "${PEERING_A_ID}" "pendingAcceptance" "TransitGatewayPeeringAttachments[0].State"
    fi

    # ピアリングの承認 (B側)
    PEERING_B_ID=$(aws_cmd "${TGW_B_REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${TGW_B_ID}" --query "TransitGatewayPeeringAttachments[?RequesterTgwInfo.TransitGatewayId=='${TGW_A_ID}' && State=='pendingAcceptance'].TransitGatewayAttachmentId | [0]")
    if [ -n "${PEERING_B_ID}" ] && [ "${PEERING_B_ID}" != "None" ]; then
        log "ピアリング (${PEERING_B_ID}) を ${TGW_B_REGION} で承認中..."
        aws_cmd "${TGW_B_REGION}" ec2 accept-transit-gateway-peering-attachment --transit-gateway-attachment-id "${PEERING_B_ID}"
    fi
    
    wait_for_state "${TGW_A_REGION}" "transit-gateway-peering-attachment" "${PEERING_A_ID}" "available" "TransitGatewayPeeringAttachments[0].State"
    log "ピアリング ${NAME} が 'available' になりました。"
}

# ルーティング設定
function configure_routing() {
    log "ルーティング設定を開始します..."

    # TGWルートテーブルへの静的ルート追加 (ピアリング経由)
    local p_idx=1
    while eval "test -v PEERING_${p_idx}_ENABLED"; do
        eval "local ENABLED=\${PEERING_${p_idx}_ENABLED}"
        if [ "${ENABLED}" == "true" ]; then
            eval "local TGW_A_IDX=\${PEERING_${p_idx}_TGW_A_INDEX}"
            eval "local TGW_A_ACCOUNT_VAR=\${TGW_${TGW_A_IDX}_ACCOUNT_ID_VAR}"
            eval "local TGW_A_ACCOUNT_ID=\${${TGW_A_ACCOUNT_VAR}}"
            if [ "${CURRENT_ACCOUNT_ID}" == "${TGW_A_ACCOUNT_ID}" ]; then
                log "HUB: ピアリング ${p_idx} のルーティングを設定します。"
                configure_peering_routes_for_tgw "${p_idx}" "A" "B"
                configure_peering_routes_for_tgw "${p_idx}" "B" "A"
            fi
        fi
        p_idx=$((p_idx + 1))
    done

    # VPCルートテーブルへのルート追加
    local v_idx=1
    while eval "test -v VPC_${v_idx}_ENABLED"; do
        eval "local ENABLED=\${VPC_${v_idx}_ENABLED}"
        eval "local ACCOUNT_ID_VAR=\${VPC_${v_idx}_ACCOUNT_ID_VAR}"
        eval "local ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
        if [ "${ENABLED}" == "true" ] && [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ]; then
            log "VPC ${v_idx} のルートテーブルを設定します。"
            configure_vpc_routes "${v_idx}"
        fi
        v_idx=$((v_idx + 1))
    done
}

# TGWピアリングルート設定のヘルパー関数
function configure_peering_routes_for_tgw() {
    local PEERING_IDX=$1; local SRC_TGW_SUFFIX=$2; local DST_TGW_SUFFIX=$3

    eval "local SRC_TGW_IDX=\${PEERING_${PEERING_IDX}_TGW_${SRC_TGW_SUFFIX}_INDEX}"
    eval "local DST_TGW_IDX=\${PEERING_${PEERING_IDX}_TGW_${DST_TGW_SUFFIX}_INDEX}"
    local SRC_TGW_ID=${TGW_IDS[${SRC_TGW_IDX}]}; local DST_TGW_ID=${TGW_IDS[${DST_TGW_IDX}]}
    eval "local SRC_TGW_REGION=\${TGW_${SRC_TGW_IDX}_REGION}"

    local PEERING_ATTACHMENT_ID=$(aws_cmd "${SRC_TGW_REGION}" ec2 describe-transit-gateway-peering-attachments --filters "Name=transit-gateway-id,Values=${SRC_TGW_ID}" --query "TransitGatewayPeeringAttachments[?(AccepterTgwInfo.TransitGatewayId=='${DST_TGW_ID}' || RequesterTgwInfo.TransitGatewayId=='${DST_TGW_ID}') && State=='available'].TransitGatewayAttachmentId | [0]")
    if [ -z "${PEERING_ATTACHMENT_ID}" ]; then return; fi

    local TGW_RT_ID=$(aws_cmd "${SRC_TGW_REGION}" ec2 describe-transit-gateway-route-tables --filters "Name=transit-gateway-id,Values=${SRC_TGW_ID}" "Name=default-association-route-table,Values=true" --query "TransitGatewayRouteTables[0].TransitGatewayRouteTableId")

    for vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
        eval "local ATTACH_TGW_IDX=\${VPC_${vpc_idx}_ATTACH_TO_TGW_INDEX}"
        if [ "${ATTACH_TGW_IDX}" == "${DST_TGW_IDX}" ]; then
            local DEST_CIDR=${ALL_VPC_CIDRS[${vpc_idx}]}
            log "TGW RT ${TGW_RT_ID} にルートを追加: ${DEST_CIDR} -> ${PEERING_ATTACHMENT_ID}"
            aws_cmd "${SRC_TGW_REGION}" ec2 create-transit-gateway-route --destination-cidr-block "${DEST_CIDR}" --transit-gateway-attachment-id "${PEERING_ATTACHMENT_ID}" --transit-gateway-route-table-id "${TGW_RT_ID}" >/dev/null 2>&1 || log "ルート ${DEST_CIDR} は既に存在するか、作成に失敗しました。"
        fi
    done
}

# VPCルート設定のヘルパー関数
function configure_vpc_routes() {
    local VPC_IDX=$1
    eval "local RT_IDS_STR=\${VPC_${VPC_IDX}_ROUTE_TABLE_IDS}"
    eval "local TGW_IDX=\${VPC_${VPC_IDX}_ATTACH_TO_TGW_INDEX}"
    eval "local TGW_REGION=\${TGW_${TGW_IDX}_REGION}"
    eval "local ACCOUNT_ID_VAR=\${VPC_${VPC_IDX}_ACCOUNT_ID_VAR}"
    eval "local ACCOUNT_ID=\${${ACCOUNT_ID_VAR}}"
    eval "local RAM_SHARE_NAME=\${VPC_${VPC_IDX}_CROSS_ACCOUNT_RAM_SHARE_NAME}"
    local TGW_ID=${TGW_IDS[${TGW_IDX}]}

    log "VPC ${VPC_IDX} ルート設定: ACCOUNT_ID=${ACCOUNT_ID}, RAM_SHARE=${RAM_SHARE_NAME}, TGW_ID=${TGW_ID}"

    # スポーク側でTGW_IDが空の場合は共有TGWを検索
    if [ -z "${TGW_ID}" ] && [ "${CURRENT_ACCOUNT_ID}" == "${ACCOUNT_ID}" ] && [ -n "${RAM_SHARE_NAME}" ]; then
        log "スポーク側VPC ${VPC_IDX}: 共有TGWを検索中..."
        eval "local HUB_ACCOUNT_ID_VAR=\${TGW_${TGW_IDX}_ACCOUNT_ID_VAR}"
        eval "local HUB_ACCOUNT_ID=\${${HUB_ACCOUNT_ID_VAR}}"
        
        # 共有リソースから検索
        eval "local TGW_NAME=\${TGW_${TGW_IDX}_NAME}"
        # 共有リソースから検索 (process_spoke_vpc_attachmentと同じロジック)
        SHARED_TGW_ARN=$(aws_cmd "${TGW_REGION}" ram list-resources --resource-owner OTHER-ACCOUNTS --resource-share-arns \
            "$(aws_cmd "${TGW_REGION}" ram get-resource-shares --name "${RAM_SHARE_NAME}" --resource-owner OTHER-ACCOUNTS --query "resourceShares[?status=='ACTIVE'].resourceShareArn | [0]")" \
            --resource-type "ec2:TransitGateway" --query "resources[0].arn" 2>/dev/null)
        if [ -n "${SHARED_TGW_ARN}" ] && [ "${SHARED_TGW_ARN}" != "None" ]; then
            TGW_ID=$(echo "${SHARED_TGW_ARN}" | awk -F'/' '{print $2}')
            log "共有リソースARNから取得したTGW ID: ${TGW_ID}"
        fi
        
        # フォールバック: Owner IDとNameタグで検索
        if [ -z "${TGW_ID}" ] || [ "${TGW_ID}" == "None" ]; then
            TGW_ID=$(aws_cmd "${TGW_REGION}" ec2 describe-transit-gateways --filters "Name=owner-id,Values=${HUB_ACCOUNT_ID}" "Name=tag:Name,Values=${TGW_NAME}" "Name=state,Values=available" --query 'TransitGateways[0].TransitGatewayId' 2>/dev/null)
            log "Owner IDとNameタグ検索から取得したTGW ID: ${TGW_ID}"
        fi
    fi

    if [ -z "${TGW_ID}" ] || [ "${TGW_ID}" == "None" ]; then
        warn "VPC ${VPC_IDX} のルート設定: TGW IDが取得できません。スキップします。"
        return
    fi

    log "VPC ${VPC_IDX} のルート設定を開始: TGW_ID=${TGW_ID}"
    read -ra RT_IDS <<< "${RT_IDS_STR}"
    for rt_id in "${RT_IDS[@]}"; do
        log "ルートテーブル ${rt_id} にルートを設定中..."
        for other_vpc_idx in "${!ALL_VPC_CIDRS[@]}"; do
            if [ "${VPC_IDX}" != "${other_vpc_idx}" ]; then
                local DEST_CIDR=${ALL_VPC_CIDRS[${other_vpc_idx}]}
                log "VPC RT ${rt_id} にルートを追加: ${DEST_CIDR} -> ${TGW_ID}"
                aws_cmd "${TGW_REGION}" ec2 create-route --route-table-id "${rt_id}" --destination-cidr-block "${DEST_CIDR}" --transit-gateway-id "${TGW_ID}" >/dev/null 2>&1 || log "ルート ${DEST_CIDR} は既に存在するか、作成に失敗しました。"
            fi
        done
    done
    log "VPC ${VPC_IDX} のルート設定完了"
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

step "1. 全VPCのCIDR情報を収集"
i=1
while eval "test -v VPC_${i}_ENABLED"; do
    eval "ENABLED=\${VPC_${i}_ENABLED}"
    if [ "${ENABLED}" == "true" ]; then
        eval "CIDR=\${VPC_${i}_VPC_CIDR}"
        ALL_VPC_CIDRS[${i}]=${CIDR}
        log "VPC ${i} のCIDR (${CIDR}) を収集しました。"
    fi
    i=$((i + 1))
done

step "2. TGWの処理 (ハブアカウントの場合)"
j=1
while eval "test -v TGW_${j}_REGION"; do
    process_tgw $j
    j=$((j + 1))
done

step "3. VPCアタッチメントとRAM共有の処理"
k=1
while eval "test -v VPC_${k}_ENABLED"; do
    process_vpc_attachment $k
    k=$((k + 1))
done

step "5. TGWピアリングの処理 (ハブアカウントの場合)"
l=1
while eval "test -v PEERING_${l}_ENABLED"; do
    process_peering $l
    l=$((l + 1))
done

step "6. ルーティングの設定"
configure_routing

step "スクリプトの処理が完了しました。"
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))
log "総経過時間: $((ELAPSED_TIME / 60)) 分 $((ELAPSED_TIME % 60)) 秒"
