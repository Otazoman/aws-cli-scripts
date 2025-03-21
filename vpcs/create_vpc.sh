#!/bin/bash

# スクリプト実行時にファイル名を指定
if [ -z "$1" ]; then
    echo "Usage: $0 <rules-file>" >&2
    exit 1
fi

RESOURCE_FILE=$1

# リソースファイルが存在するか確認
if [ ! -f "$RESOURCE_FILE" ]; then
    echo "エラー: ファイル $RESOURCE_FILE が見つかりません。"
    exit 1
fi

# リソースファイルを読み込み、ヘッダーをスキップ
RESOURCES=()
while IFS= read -r line; do
    if [[ ! "$line" =~ ^REGION ]]; then
        RESOURCES+=("$line")
    fi
done < "$RESOURCE_FILE"

# リージョンごとの処理
for RESOURCE in "${RESOURCES[@]}"; do
    IFS=',' read -r REGION VPC_NAME VPC_CIDR SUBNET_CIDR AZ TYPE NAME ROUTE_TABLE_NAME COST_TAG <<< "${RESOURCE}"
    
    # リージョンが切り替わった場合、変数をリセット
    if [ "$REGION" != "$CURRENT_REGION" ]; then
        unset PROCESSED_VPCS
        unset ROUTE_TABLES
        unset NAT_GATEWAYS
        unset FIRST_PUBLIC_SUBNETS
    
        echo "リージョンが切り替わりました: ${REGION}"
        CURRENT_REGION=$REGION
        declare -A PROCESSED_VPCS
        declare -A ROUTE_TABLES
        declare -A NAT_GATEWAYS
        declare -A FIRST_PUBLIC_SUBNETS
    fi

    # リージョンとVPCごとに処理を開始
    if [ -z "${PROCESSED_VPCS[$VPC_NAME]}" ]; then
        echo "リージョン ${REGION} の VPC ${VPC_NAME} の処理を開始します..."
        
        # VPC作成または既存のVPC取得
        EXISTING_VPC_ID=$(aws ec2 describe-vpcs \
          --region $REGION \
          --filters "Name=tag:Name,Values=${VPC_NAME}" \
          --query 'Vpcs[0].VpcId' \
          --output text)

        if [ "$EXISTING_VPC_ID" != "None" ]; then
            echo "既存のVPCを使用します: ${EXISTING_VPC_ID}"
            EC2_VPC_ID=$EXISTING_VPC_ID
            
            # 既存のIGWを取得
            IGW_ID=$(aws ec2 describe-internet-gateways \
              --region $REGION \
              --filters "Name=attachment.vpc-id,Values=${EC2_VPC_ID}" \
              --query 'InternetGateways[0].InternetGatewayId' \
              --output text)
            echo "既存のインターネットゲートウェイ ID: ${IGW_ID}"
        else
            echo "VPCを作成中..."
            EC2_VPC_ID=$(aws ec2 create-vpc \
              --region $REGION \
              --cidr-block ${VPC_CIDR} \
              --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${VPC_NAME}},{Key=CostDiv,Value=${COST_TAG}}]" \
              --query 'Vpc.VpcId' \
              --output text)
            echo "VPC ID: ${EC2_VPC_ID}"

            # インターネットゲートウェイ作成とアタッチ
            echo "インターネットゲートウェイを作成中..."
            IGW_ID=$(aws ec2 create-internet-gateway \
              --region $REGION \
              --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${VPC_NAME}-igw},{Key=CostDiv,Value=${COST_TAG}}]" \
              --query 'InternetGateway.InternetGatewayId' \
              --output text)
            aws ec2 attach-internet-gateway --region $REGION --internet-gateway-id ${IGW_ID} --vpc-id ${EC2_VPC_ID}
            echo "インターネットゲートウェイ ID: ${IGW_ID}"
        fi
        
        PROCESSED_VPCS[$VPC_NAME]=1
    fi

    # サブネット作成
    echo "サブネット ${NAME} を作成中..."
    SUBNET_ID=$(aws ec2 create-subnet \
      --region $REGION \
      --vpc-id ${EC2_VPC_ID} \
      --cidr-block ${SUBNET_CIDR} \
      --availability-zone ${AZ} \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-${NAME}},{Key=CostDiv,Value=${COST_TAG}}]" \
      --query 'Subnet.SubnetId' \
      --output text 2>/dev/null || echo "")
    
    if [ -z "$SUBNET_ID" ]; then
        echo "サブネットの作成に失敗しました。CIDRブロックや設定を確認してください。"
        continue
    fi
    
    echo "${TYPE} サブネット (${AZ}) ID: ${SUBNET_ID}"
    
    # パブリックサブネットの場合、パブリックIP自動割り当てを有効化
    if [[ "${TYPE}" == public ]]; then
        aws ec2 modify-subnet-attribute --region $REGION --subnet-id ${SUBNET_ID} --map-public-ip-on-launch
        if [ -z "${FIRST_PUBLIC_SUBNETS[$VPC_NAME]}" ]; then
            FIRST_PUBLIC_SUBNETS[$VPC_NAME]=${SUBNET_ID}
        fi
    fi

    # ルートテーブル作成または取得（必要に応じて）
    if [ -z "${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]}" ]; then
        EXISTING_RT_ID=$(aws ec2 describe-route-tables \
          --region $REGION \
          --filters "Name=vpc-id,Values=${EC2_VPC_ID}" "Name=tag:Name,Values=${VPC_NAME}-${ROUTE_TABLE_NAME}" \
          --query 'RouteTables[0].RouteTableId' \
          --output text)
        
        if [ "$EXISTING_RT_ID" != "None" ]; then
            echo "既存のルートテーブルを使用します: ${EXISTING_RT_ID}"
            ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]=$EXISTING_RT_ID
        else
            echo "ルートテーブル ${ROUTE_TABLE_NAME} を作成中..."
            RT_ID=$(aws ec2 create-route-table \
              --region $REGION \
              --vpc-id ${EC2_VPC_ID} \
              --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${VPC_NAME}-${ROUTE_TABLE_NAME}},{Key=CostDiv,Value=${COST_TAG}}]" \
              --query 'RouteTable.RouteTableId' \
              --output text)
            ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]=$RT_ID
            echo "ルートテーブル ID: ${RT_ID}"
            
            # パブリックルートの場合、インターネットゲートウェイを設定
            if [[ "${TYPE}" == public ]]; then
                aws ec2 create-route \
                  --region $REGION \
                  --route-table-id $RT_ID \
                  --destination-cidr-block '0.0.0.0/0' \
                  --gateway-id $IGW_ID
            fi
        fi
    fi

    # サブネットとルートテーブルの関連付け
    aws ec2 associate-route-table \
      --region $REGION \
      --subnet-id $SUBNET_ID \
      --route-table-id ${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]}

    # NATゲートウェイが必要な場合（`private-nat` タイプ）
    if [[ "${TYPE}" == private-nat ]]; then
        NAT_GATEWAY_KEY="${VPC_NAME},${AZ}-natgw"
        
        if [ -z "${NAT_GATEWAYS[$NAT_GATEWAY_KEY]}" ]; then
            EXISTING_NAT_GATEWAY=$(aws ec2 describe-nat-gateways \
              --region $REGION \
              --filter "Name=vpc-id,Values=${EC2_VPC_ID}" "Name=subnet-id,Values=${FIRST_PUBLIC_SUBNETS[$VPC_NAME]}" \
              "Name=state,Values=available" \
              --query 'NatGateways[?Tags[?Key==`Name` && Value==`'"${VPC_NAME}-${AZ}-natgw"'`]].NatGatewayId' \
              --output text)
            
            if [ -n "$EXISTING_NAT_GATEWAY" ] && [ "$EXISTING_NAT_GATEWAY" != "None" ]; then
                echo "既存のNATゲートウェイを使用します (${AZ}): $EXISTING_NAT_GATEWAY"
                NAT_GATEWAYS[$NAT_GATEWAY_KEY]=$EXISTING_NAT_GATEWAY
            else
                echo "NATゲートウェイを作成中 (${AZ})..."
                EIP_ALLOC_ID=$(aws ec2 allocate-address \
                  --region $REGION \
                  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${VPC_NAME}-${AZ}-natgw-ip},{Key=CostDiv,Value=${COST_TAG}}]" \
                  --query 'AllocationId' \
                  --output text)
                NAT_GATEWAY_ID=$(aws ec2 create-nat-gateway \
                  --region $REGION \
                  --subnet-id ${FIRST_PUBLIC_SUBNETS[$VPC_NAME]} \
                  --allocation-id $EIP_ALLOC_ID \
                  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${VPC_NAME}-${AZ}-natgw},{Key=CostDiv,Value=${COST_TAG}}]" \
                  --query 'NatGateway.NatGatewayId' \
                  --output text)
                NAT_GATEWAYS[$NAT_GATEWAY_KEY]=$NAT_GATEWAY_ID
                
                # NATゲートウェイが利用可能になるまで待機
                echo "NATゲートウェイ (${AZ}) の準備を待機中..."
                aws ec2 wait nat-gateway-available --region $REGION --nat-gateway-ids $NAT_GATEWAY_ID
                
                # プライベートルートテーブルにNATゲートウェイルートを追加
                aws ec2 create-route \
                  --region $REGION \
                  --route-table-id ${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]} \
                  --destination-cidr-block '0.0.0.0/0' \
                  --nat-gateway-id $NAT_GATEWAY_ID
                echo "NATゲートウェイルートを追加しました (${AZ})"
            fi
        fi
    fi
done

echo "全てのリージョンとVPCの処理が完了しました！"
