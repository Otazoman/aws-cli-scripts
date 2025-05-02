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
HEADER_SKIPPED=false
while IFS= read -r line; do
    # ヘッダー行をスキップ
    if ! "$HEADER_SKIPPED"; then
        if [[ "$line" =~ ^REGION, ]]; then # "REGION,"で始まる行をヘッダーと見なす
            HEADER_SKIPPED=true
            continue
        fi
    fi
    # 空行またはコメント行をスキップ
    if [[ -z "$line" || "$line" =~ ^# ]]; then
        continue
    fi

    RESOURCES+=("$line")
done < "$RESOURCE_FILE"

# タグ文字列を生成する関数
# $1: リソースのNameタグの値
# $2: CSVから読み込んだセミコロン区切りのタグ文字列 (Key1=Value1;Key2=Value2...)
build_tag_string() {
    local resource_name="$1"
    local raw_tags="$2"
    local tag_array=()

    # 必ず Name タグを追加
    tag_array+=("{Key=Name,Value=${resource_name}}")

    # CSVから読み込んだタグを追加
    if [ -n "$raw_tags" ]; then
        IFS=';' read -ra tag_pairs <<< "$raw_tags"
        for pair in "${tag_pairs[@]}"; do
            if [[ "$pair" =~ ^[^=]+=[^=]*$ ]]; then # "Key=Value" 形式か簡単なチェック
                IFS='=' read -r tag_key tag_value <<< "$pair"
                tag_array+=("{Key=${tag_key},Value=${tag_value}}")
            else
                echo "警告: 無効なタグ形式をスキップします: '$pair'" >&2
            fi
        done
    fi

    # 配列をカンマ区切りの文字列に結合
    IFS=','
    echo "${tag_array[*]}"
}


# リージョンごとの処理
for RESOURCE in "${RESOURCES[@]}"; do
    # CSVの列を読み込み - COST_TAG を TAGS に変更
    IFS=',' read -r REGION VPC_NAME VPC_CIDR SUBNET_CIDR AZ TYPE NAME ROUTE_TABLE_NAME TAGS <<< "${RESOURCE}"

    # リージョンが切り替わった場合、変数をリセット
    if [ "$REGION" != "$CURRENT_REGION" ]; then
        unset PROCESSED_VPCS
        unset ROUTE_TABLES
        unset NAT_GATEWAYS
        unset FIRST_PUBLIC_SUBNETS

        echo "--------------------------------------------------"
        echo "リージョンが切り替わりました: ${REGION}"
        echo "--------------------------------------------------"
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

            # 既存のIGWを取得 (VPCにアタッチされているもの)
            IGW_ID=$(aws ec2 describe-internet-gateways \
              --region $REGION \
              --filters "Name=attachment.vpc-id,Values=${EC2_VPC_ID}" \
              --query 'InternetGateways[0].InternetGatewayId' \
              --output text)
            if [ "$IGW_ID" != "None" ]; then
              echo "既存のインターネットゲートウェイ ID: ${IGW_ID}"
            else
              echo "エラー: 既存のVPCにインターネットゲートウェイが見つかりません。"
              # 必要に応じてここでエラーハンドリングを追加 (例: スクリプト停止など)
              # exit 1
            fi

        else
            echo "VPCを作成中..."
            # VPCのタグ文字列を生成
            VPC_TAG_STRING=$(build_tag_string "${VPC_NAME}" "${TAGS}")

            EC2_VPC_ID=$(aws ec2 create-vpc \
              --region $REGION \
              --cidr-block ${VPC_CIDR} \
              --tag-specifications "ResourceType=vpc,Tags=[${VPC_TAG_STRING}]" \
              --query 'Vpc.VpcId' \
              --output text)

            # VPC作成失敗時のエラーハンドリング
            if [ -z "$EC2_VPC_ID" ]; then
                echo "エラー: VPCの作成に失敗しました。リージョン、CIDRブロック、権限等を確認してください。"
                # このVPCに関連する以降のリソース作成をスキップするか、スクリプトを終了するか検討
                continue # 現在のVPCに関する処理をスキップ
            fi
            echo "VPC ID: ${EC2_VPC_ID}"

            # インターネットゲートウェイ作成とアタッチ
            echo "インターネットゲートウェイを作成中..."
            # IGWのタグ文字列を生成
            IGW_TAG_STRING=$(build_tag_string "${VPC_NAME}-igw" "${TAGS}")

            IGW_ID=$(aws ec2 create-internet-gateway \
              --region $REGION \
              --tag-specifications "ResourceType=internet-gateway,Tags=[${IGW_TAG_STRING}]" \
              --query 'InternetGateway.InternetGatewayId' \
              --output text)

            # IGW作成失敗時のエラーハンドリング
             if [ -z "$IGW_ID" ]; then
                echo "エラー: インターネットゲートウェイの作成に失敗しました。"
                # VPCをロールバックするか、スクリプトを終了するか検討
                # aws ec2 delete-vpc --region $REGION --vpc-id $EC2_VPC_ID # 例: VPC削除
                continue # 現在のVPCに関する処理をスキップ
            fi
            echo "インターネットゲートウェイ ID: ${IGW_ID}"

            # IGWアタッチ
            aws ec2 attach-internet-gateway \
              --region $REGION \
              --internet-gateway-id ${IGW_ID} \
              --vpc-id ${EC2_VPC_ID}

            # アタッチ失敗時のエラーハンドリングは必要に応じて追加
        fi

        PROCESSED_VPCS[$VPC_NAME]=1
    fi

    # サブネット作成
    echo "サブネット ${NAME} を作成中..."
    # サブネットのタグ文字列を生成
    SUBNET_TAG_STRING=$(build_tag_string "${VPC_NAME}-${NAME}" "${TAGS}")

    SUBNET_ID=$(aws ec2 create-subnet \
      --region $REGION \
      --vpc-id ${EC2_VPC_ID} \
      --cidr-block ${SUBNET_CIDR} \
      --availability-zone ${AZ} \
      --tag-specifications "ResourceType=subnet,Tags=[${SUBNET_TAG_STRING}]" \
      --query 'Subnet.SubnetId' \
      --output text 2>/dev/null || echo "") # エラーメッセージを抑制し、IDが取得できなければ空文字にする

    if [ -z "$SUBNET_ID" ]; then
        echo "エラー: サブネットの作成に失敗しました。CIDRブロック、AZ、権限等を確認してください。"
        continue # このサブネットの処理をスキップ
    fi

    echo "${TYPE} サブネット (${AZ}) ID: ${SUBNET_ID}"

    # パブリックサブネットの場合、パブリックIP自動割り当てを有効化
    if [[ "${TYPE}" == public ]]; then
        aws ec2 modify-subnet-attribute \
          --region $REGION \
          --subnet-id ${SUBNET_ID} \
          --map-public-ip-on-launch
        # 最初に見つかったパブリックサブネットをNAT GW作成用に記録
        if [ -z "${FIRST_PUBLIC_SUBNETS[$VPC_NAME]}" ]; then
            FIRST_PUBLIC_SUBNETS[$VPC_NAME]=${SUBNET_ID}
        fi
    fi

    # ルートテーブル作成または取得（必要に応じて）
    if [ -z "${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]}" ]; then
        # 既存のルートテーブルをタグで検索
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
            # ルートテーブルのタグ文字列を生成
            RT_TAG_STRING=$(build_tag_string "${VPC_NAME}-${ROUTE_TABLE_NAME}" "${TAGS}")

            RT_ID=$(aws ec2 create-route-table \
              --region $REGION \
              --vpc-id ${EC2_VPC_ID} \
              --tag-specifications "ResourceType=route-table,Tags=[${RT_TAG_STRING}]" \
              --query 'RouteTable.RouteTableId' \
              --output text)

            # RT作成失敗時のエラーハンドリング
            if [ -z "$RT_ID" ]; then
                echo "エラー: ルートテーブル '${ROUTE_TABLE_NAME}' の作成に失敗しました。"
                 continue # このルートテーブルに関連する処理をスキップ (サブネットの関連付けなど)
            fi

            ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]=$RT_ID
            echo "ルートテーブル ID: ${RT_ID}"

            # パブリックルートの場合、インターネットゲートウェイへのデフォルトルート(0.0.0.0/0)を設定
            # NOTE: プライベートでもデフォルトルートが必要な場合は、ここで設定するのではなく、
            # NAT GW作成時に別途ルートを作成する (スクリプト後半で実施)
            if [[ "${TYPE}" == public ]]; then
                echo "パブリックルートテーブルにインターネットゲートウェイルートを追加..."
                aws ec2 create-route \
                  --region $REGION \
                  --route-table-id $RT_ID \
                  --destination-cidr-block '0.0.0.0/0' \
                  --gateway-id $IGW_ID 2>/dev/null # すでにルートが存在する場合はエラーになるが無視
                # エラーハンドリングが必要な場合は、2>/dev/null を削除し、$? を確認
            fi
        fi
    fi

    # サブネットとルートテーブルの関連付け
    echo "サブネット ${SUBNET_ID} をルートテーブル ${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]} に関連付け中..."
    aws ec2 associate-route-table \
      --region $REGION \
      --subnet-id $SUBNET_ID \
      --route-table-id ${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]}

    # NATゲートウェイが必要な場合（`private-nat` タイプ）
    if [[ "${TYPE}" == private-nat ]]; then
        NAT_GATEWAY_KEY="${VPC_NAME},${AZ}-natgw" # VPC名とAZで一意になるキー
        NAT_RT_KEY="${VPC_NAME},${ROUTE_TABLE_NAME}" # プライベートサブネットに関連付けるルートテーブルのキー

        # このNATゲートウェイの作成が、このVPC/AZの組み合わせで初めてか確認
        if [ -z "${NAT_GATEWAYS[$NAT_GATEWAY_KEY]}" ]; then
            echo "NATゲートウェイ (${AZ}) の処理を開始します..."

            # NAT GWを配置するパブリックサブネットのIDを取得
            # スクリプトでは最初に見つかったパブリックサブネットを使用することを想定
            # もし各AZにNAT GWを配置し、それぞれのAZ内のパブリックサブネットに配置したい場合は、
            # FIRST_PUBLIC_SUBNETS のキーを ${VPC_NAME},${AZ} のように変更し、
            # サブネット作成時に各AZのパブリックサブネットを記録する必要があります。
            PUBLIC_SUBNET_FOR_NAT=${FIRST_PUBLIC_SUBNETS[$VPC_NAME]}

            if [ -z "$PUBLIC_SUBNET_FOR_NAT" ]; then
                echo "エラー: NATゲートウェイ (${AZ}) を配置するためのパブリックサブネットが '${VPC_NAME}' VPCに見つかりませんでした。先に少なくとも1つのpublicタイプのサブネットを作成してください。"
                continue # NAT GWおよびそれに関連するルート作成をスキップ
            fi
            echo "NATゲートウェイ (${AZ}) を配置するパブリックサブネット: ${PUBLIC_SUBNET_FOR_NAT}"

            # 既存のNATゲートウェイを検索 (タグとステータスで絞り込み)
             EXISTING_NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways \
              --region $REGION \
              --filter "Name=vpc-id,Values=${EC2_VPC_ID}" "Name=subnet-id,Values=${PUBLIC_SUBNET_FOR_NAT}" "Name=state,Values=available" \
              --query 'NatGateways[?Tags[?Key==`Name` && Value==`'"${VPC_NAME}-${AZ}-natgw"'`]].NatGatewayId' \
              --output text)

            if [ -n "$EXISTING_NAT_GATEWAY_ID" ] && [ "$EXISTING_NAT_GATEWAY_ID" != "None" ]; then
                echo "既存のNATゲートウェイを使用します (${AZ}): $EXISTING_NAT_GATEWAY_ID"
                NAT_GATEWAYS[$NAT_GATEWAY_KEY]=$EXISTING_NAT_GATEWAY_ID
            else
                echo "NATゲートウェイを作成中 (${AZ})..."
                # NAT GW用のEIPタグ文字列を生成
                EIP_TAG_STRING=$(build_tag_string "${VPC_NAME}-${AZ}-natgw-ip" "${TAGS}")

                EIP_ALLOC_ID=$(aws ec2 allocate-address \
                  --region $REGION \
                  --tag-specifications "ResourceType=elastic-ip,Tags=[${EIP_TAG_STRING}]" \
                  --query 'AllocationId' \
                  --output text)

                # EIP作成失敗時のエラーハンドリング
                 if [ -z "$EIP_ALLOC_ID" ]; then
                    echo "エラー: NATゲートウェイ (${AZ}) 用のElastic IPの割り当てに失敗しました。"
                    continue # NAT GW作成をスキップ
                fi
                 echo "Elastic IP 割り当てID: ${EIP_ALLOC_ID}"

                # NAT GWのタグ文字列を生成
                NAT_GATEWAY_TAG_STRING=$(build_tag_string "${VPC_NAME}-${AZ}-natgw" "${TAGS}")

                NAT_GATEWAY_ID=$(aws ec2 create-nat-gateway \
                  --region $REGION \
                  --subnet-id ${PUBLIC_SUBNET_FOR_NAT} \
                  --allocation-id $EIP_ALLOC_ID \
                  --tag-specifications "ResourceType=natgateway,Tags=[${NAT_GATEWAY_TAG_STRING}]" \
                  --query 'NatGateway.NatGatewayId' \
                  --output text)

                # NAT GW作成失敗時のエラーハンドリング
                 if [ -z "$NAT_GATEWAY_ID" ]; then
                    echo "エラー: NATゲートウェイ (${AZ}) の作成に失敗しました。"
                    # 割り当てたEIPを解放するか検討 (cleanup処理など)
                    aws ec2 release-address --region $REGION --allocation-id $EIP_ALLOC_ID 2>/dev/null
                    continue # NAT GWに関連する処理をスキップ
                fi

                NAT_GATEWAYS[$NAT_GATEWAY_KEY]=$NAT_GATEWAY_ID
                echo "NATゲートウェイ ID (${AZ}): ${NAT_GATEWAY_ID}"

                # NATゲートウェイが利用可能になるまで待機
                echo "NATゲートウェイ (${AZ}) の準備を待機中..."
                # wait コマンドが失敗してもスクリプトは止めないが、NAT GWがREADYでないとルートは機能しない点に注意
                aws ec2 wait nat-gateway-available --region $REGION --nat-gateway-ids $NAT_GATEWAY_ID || echo "警告: NATゲートウェイ (${AZ}) が利用可能になるのを待機中に問題が発生したか、タイムアウトしました。"

                # このAZのプライベートルートテーブルにNATゲートウェイルートを追加
                # NAT GWを作成したAZのプライベートサブネットと同じルートテーブルに関連付けられているはず
                # ルートテーブルIDを取得
                NAT_RT_ID=${ROUTE_TABLES[$VPC_NAME,$ROUTE_TABLE_NAME]}

                if [ -z "$NAT_RT_ID" ]; then
                    echo "エラー: NATゲートウェイ (${AZ}) に関連付けるルートテーブル '${ROUTE_TABLE_NAME}' が見つかりません。"
                    # このNAT GWは機能しないが、スクリプトは続行
                else
                    echo "プライベートルートテーブル ${NAT_RT_ID} にNATゲートウェイルート (${AZ}) を追加..."
                    # 既存のデフォルトルートがないか確認してからの作成がより丁寧だが、ここでは単純に作成を試みる
                     aws ec2 create-route \
                      --region $REGION \
                      --route-table-id $NAT_RT_ID \
                      --destination-cidr-block '0.0.0.0/0' \
                      --nat-gateway-id $NAT_GATEWAY_ID 2>/dev/null # すでにデフォルトルートが存在する場合はエラーになるが無視
                     # エラーハンドリングが必要な場合は、2>/dev/null を削除し、$? を確認
                fi
            fi
        fi
    fi
done

echo "--------------------------------------------------"
echo "全てのリージョンとVPCの処理が完了しました。"
echo "--------------------------------------------------"
