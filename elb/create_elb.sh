#!/bin/bash

# 引数チェック
if [ $# -eq 0 ]; then
    echo "エラー: CSVファイルを引数として指定してください"
    echo "使用例: $0 loadbalancers.csv"
    exit 1
fi

CSV_FILE="$1"

# CSVファイル存在チェック
if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: 指定されたCSVファイルが見つかりません: $CSV_FILE"
    exit 1
fi

echo "ロードバランサー作成処理を開始します..."
echo "使用するCSVファイル: $CSV_FILE"
echo "--------------------------------------------------"

# ロードバランサーの状態を確認し、activeになるまで待機する関数
wait_for_load_balancer() {
    local REGION=$1
    local LB_ARN=$2
    local MAX_RETRIES=30
    local SLEEP_TIME=10
    local COUNT=0

    echo "  ロードバランサーがactive状態になるのを待機しています..."

    while [ $COUNT -lt $MAX_RETRIES ]; do
        local STATE=$(aws elbv2 describe-load-balancers \
            --load-balancer-arns "$LB_ARN" \
            --query "LoadBalancers[0].State.Code" \
            --output text \
            --region "$REGION")

        if [ "$STATE" == "active" ]; then
            echo "  ロードバランサーがactive状態になりました"
            return 0
        elif [ "$STATE" == "failed" ]; then
            echo "  エラー: ロードバランサーの作成に失敗しました"
            return 1
        fi

        echo "  現在の状態: $STATE (${COUNT}/${MAX_RETRIES} 回目)..."
        sleep $SLEEP_TIME
        COUNT=$((COUNT + 1))
    done

    echo "  警告: ロードバランサーがactive状態になるまでに時間がかかっています"
    return 1
}

# S3バケットを作成する関数
create_s3_bucket() {
    local REGION=$1
    local BUCKET_NAME=$2
    local TAGS=$3 # オプションのタグ

    echo "  S3バケット '$BUCKET_NAME' を作成します..."

    # リージョンがus-east-1の場合はLocationConstraintを指定しない
    local CREATE_BUCKET_ARGS=("--bucket" "$BUCKET_NAME" "--region" "$REGION")
    if [ "$REGION" != "us-east-1" ]; then
        CREATE_BUCKET_ARGS+=("--create-bucket-configuration" "LocationConstraint=$REGION")
    fi
    aws s3api create-bucket "${CREATE_BUCKET_ARGS[@]}"

    if [ $? -eq 0 ]; then
        echo "  S3バケット '$BUCKET_NAME' の作成に成功しました"

        # バケットのバージョニングを有効化
        aws s3api put-bucket-versioning \
            --bucket "$BUCKET_NAME" \
            --versioning-configuration Status=Enabled \
            --region "$REGION"
        if [ $? -ne 0 ]; then
            echo "  警告: S3バケットのバージョニングの有効化に失敗しました"
        else
            echo "  S3バケットのバージョニングを有効化しました"
        fi

        # タグ付け処理 (オプション)
        if [ -n "$TAGS" ]; then
            echo "  S3バケットにタグを設定します..."
            local TAG_SET="TagSet=["
            local FIRST=true
            IFS=';' read -ra TAG_PAIRS <<< "$TAGS"
            for TAG_PAIR_RAW in "${TAG_PAIRS[@]}"; do
                local TAG_PAIR=$(echo "$TAG_PAIR_RAW" | xargs)
                IFS='=' read -r KEY VALUE <<< "$TAG_PAIR"
                if [ "$FIRST" == true ]; then
                    TAG_SET+="{Key='$KEY',Value='$VALUE'}"
                    FIRST=false
                else
                    TAG_SET+=",{Key='$KEY',Value='$VALUE'}"
                fi
            done
            TAG_SET+="]"

            aws s3api put-bucket-tagging \
                --bucket "$BUCKET_NAME" \
                --tagging "$TAG_SET" \
                --region "$REGION"

            if [ $? -eq 0 ]; then
                echo "  S3バケットのタグ付けに成功しました"
            else
                echo "  警告: S3バケットのタグ付けに失敗しました"
            fi
        fi

        return 0
    else
        echo "  エラー: S3バケットの作成に失敗しました"
        return 1
    fi
}

# S3バケットにログ配信ポリシーを設定する関数
set_bucket_policy() {
    local BUCKET_NAME=$1
    local REGION=$2
    local LB_TYPE=$3  # "ALB" or "NLB"
    local LB_ARN=$4   # ロードバランサーARN
    local S3_PREFIX=$5
    
    echo "  S3バケットポリシーを設定しています..."
    
    # アカウントIDを取得
    local ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$ACCOUNT_ID" ]; then
        echo "  エラー: AWSアカウントIDの取得に失敗しました"
        return 1
    fi
    
    # リージョンごとのELB/NLBアカウントIDを取得
    declare -A ELB_ACCOUNTS=(
        ["us-east-1"]="127311923021"
        ["us-east-2"]="033677994240"
        ["us-west-1"]="027434742980"
        ["us-west-2"]="797873946194"
        ["ap-northeast-1"]="582318560864"
        ["ap-northeast-2"]="600734575887"
        ["ap-south-1"]="718504428378"
        ["ap-southeast-1"]="114774131450"
        ["ap-southeast-2"]="783225319266"
        ["ca-central-1"]="985666609251"
        ["eu-central-1"]="054676820928"
        ["eu-west-1"]="156460612806"
        ["eu-west-2"]="652711504416"
        ["eu-west-3"]="009996457667"
        ["sa-east-1"]="507241528517"
    )
    
    local ELB_ACCOUNT_ID="${ELB_ACCOUNTS[$REGION]}"
    if [ -z "$ELB_ACCOUNT_ID" ]; then
        echo "  エラー: リージョン '$REGION' のELBアカウントIDが不明です"
        return 1
    fi
    
    # プレフィックスを正規化
    S3_PREFIX=$(echo "$S3_PREFIX" | sed 's:^/*::;s:/*$::')  # 前後のスラッシュを除去
    
    # NLB用のポリシー
    
   if [ "$LB_TYPE" == "NLB" ]; then
        # Resourceを修正:  プレフィックスが指定されている場合も考慮
        if [ -n "$S3_PREFIX" ]; then
            local RESOURCE_PATH="${BUCKET_NAME}/${S3_PREFIX}/AWSLogs/${ACCOUNT_ID}/*"
        else
            local RESOURCE_PATH="${BUCKET_NAME}/AWSLogs/${ACCOUNT_ID}/*"
        fi 
        local POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Id": "AWSConsole-AccessLogs-Policy",
    "Statement": [
        {
            "Sid": "AWSConsoleStmt",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${ELB_ACCOUNT_ID}:root"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${RESOURCE_PATH}"
        },
        {
            "Sid": "AWSLogDeliveryWrite",
            "Effect": "Allow",
            "Principal": {
                "Service": "delivery.logs.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${RESOURCE_PATH}",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        },
        {
            "Sid": "AWSLogDeliveryAclCheck",
            "Effect": "Allow",
            "Principal": {
                "Service": "delivery.logs.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}"
        }
    ]
}
EOF
        )
    else
        # ALB用のポリシー
        local POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${ELB_ACCOUNT_ID}:root"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        },
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "delivery.logs.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}"
        }
    ]
}
EOF
        )
    fi
    
    # ポリシーを一時ファイルに保存
    local POLICY_FILE=$(mktemp)
    echo "$POLICY" > "$POLICY_FILE"
    
    aws s3api put-bucket-policy \
        --bucket "$BUCKET_NAME" \
        --policy "file://${POLICY_FILE}" \
        --region "$REGION"
    
    local RESULT=$?
    rm -f "$POLICY_FILE"
    
    if [ $RESULT -eq 0 ]; then
        echo "  S3バケットポリシーの設定に成功しました"
        return 0
    else
        echo "  エラー: S3バケットポリシーの設定に失敗しました"
        return 1
    fi
}

# VPC名またはIDからVPC IDを取得する関数
get_vpc_id() {
    local REGION=$1
    local VPC_IDENTIFIER=$2
    
    if [ -z "$VPC_IDENTIFIER" ]; then
        echo ""
        return 0
    fi
    
    if [[ $VPC_IDENTIFIER == vpc-* ]]; then
        echo "$VPC_IDENTIFIER"
        return 0
    fi
    
    echo "  VPC名 '$VPC_IDENTIFIER' からVPC IDを検索..." >&2
    local VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$VPC_IDENTIFIER" \
        --query "Vpcs[0].VpcId" \
        --output text \
        --region "$REGION")
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        echo "  エラー: VPC '$VPC_IDENTIFIER' が見つかりません。以下のVPCが存在するか確認してください:" >&2
        aws ec2 describe-vpcs --region "$REGION" --query "Vpcs[].Tags[?Key=='Name'].Value" --output text >&2
        return 1
    fi
    
    echo "$VPC_ID"
}

# サブネット名またはIDからサブネットIDを取得する関数
get_subnet_ids() {
    local REGION=$1
    local SUBNET_IDENTIFIERS=$2
    
    IFS=';' read -ra SUBNETS <<< "$SUBNET_IDENTIFIERS"
    local SUBNET_IDS=()
    
    for SUBNET in "${SUBNETS[@]}"; do
        SUBNET=$(echo "$SUBNET" | xargs)
        
        if [[ $SUBNET == subnet-* ]]; then
            SUBNET_IDS+=("$SUBNET")
        else
            echo "  サブネット名 '$SUBNET' からサブネットIDを検索..." >&2
            local SUBNET_ID=$(aws ec2 describe-subnets \
                --filters "Name=tag:Name,Values=$SUBNET" \
                --query "Subnets[0].SubnetId" \
                --output text \
                --region "$REGION")
            
            if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" == "None" ]; then
                echo "  エラー: サブネット '$SUBNET' が見つかりません。以下のサブネットが存在するか確認してください:" >&2
                aws ec2 describe-subnets --region "$REGION" --query "Subnets[].Tags[?Key=='Name'].Value" --output text >&2
                return 1
            fi
            
            SUBNET_IDS+=("$SUBNET_ID")
        fi
    done
    
    echo "${SUBNET_IDS[@]}"
}

# セキュリティグループ名またはIDからセキュリティグループIDを取得する関数
get_security_group_ids() {
    local REGION=$1
    local SG_IDENTIFIERS=$2
    local VPC_ID=$3
    
    if [ -z "$SG_IDENTIFIERS" ]; then
        echo ""
        return 0
    fi
    
    IFS=';' read -ra SGS <<< "$SG_IDENTIFIERS"
    local SG_IDS=()
    
    for SG in "${SGS[@]}"; do
        SG=$(echo "$SG" | xargs)
        
        if [[ $SG == sg-* ]]; then
            SG_IDS+=("$SG")
        else
            echo "  セキュリティグループ名 '$SG' からIDを検索..." >&2
            local SG_ID=$(aws ec2 describe-security-groups \
                --filters "Name=group-name,Values=$SG" "Name=vpc-id,Values=$VPC_ID" \
                --query "SecurityGroups[0].GroupId" \
                --output text \
                --region "$REGION")
            
            if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
                echo "  エラー: セキュリティグループ '$SG' が見つかりません。以下のセキュリティグループが存在するか確認してください:" >&2
                aws ec2 describe-security-groups --region "$REGION" \
                    --filters "Name=vpc-id,Values=$VPC_ID" \
                    --query "SecurityGroups[].[GroupId, GroupName, Tags[?Key=='Name'].Value]" \
                    --output table >&2
                return 1
            fi
            
            SG_IDS+=("$SG_ID")
        fi
    done
    
    echo "${SG_IDS[@]}"
}

# ロードバランサーARNを名前から取得する関数
get_load_balancer_arn() {
    local REGION=$1
    local LB_NAME=$2
    
    echo "  ロードバランサー名 '$LB_NAME' からARNを検索..." >&2
    local LB_ARN=$(aws elbv2 describe-load-balancers \
        --names "$LB_NAME" \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text \
        --region "$REGION")
    
    if [ -z "$LB_ARN" ] || [ "$LB_ARN" == "None" ]; then
        echo ""
        return 1
    fi
    
    echo "$LB_ARN"
}

# S3バケットの存在確認と作成
ensure_s3_bucket() {
    local REGION=$1
    local BUCKET_NAME=$2
    local LB_TYPE=$3  # "ALB" or "NLB"
    local LB_ARN=$4   # ロードバランサーARN
    local S3_PREFIX=$5
    local TAGS=$6
    
    echo "  S3バケット '$BUCKET_NAME' の存在を確認..."
    
    # バケットの存在確認
    aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "  S3バケット '$BUCKET_NAME' は既に存在します"
        # 既存バケットにもポリシーを設定
        set_bucket_policy "$BUCKET_NAME" "$REGION" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX"
        return $?
    else
        echo "  S3バケット '$BUCKET_NAME' が存在しないため、作成します"
        create_s3_bucket "$REGION" "$BUCKET_NAME" "$TAGS"
        
        if [ $? -ne 0 ]; then
            return 1
        fi
        
        # バケットポリシーを設定
        set_bucket_policy "$BUCKET_NAME" "$REGION" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX"
        return $?
    fi
}

# ロードバランサーのログ設定を行う関数
configure_load_balancer_logs() {
    local REGION=$1
    local LB_ARN=$2
    local LB_TYPE=$3
    local ENABLE_ACCESS_LOGS=$4
    local S3_BUCKET_NAME_ACCESS_LOGS=$5
    local S3_PREFIX_ACCESS_LOGS_RAW=$6
    local ENABLE_CONNECTION_LOGS=$7
    local S3_BUCKET_NAME_CONNECTION_LOGS=$8
    local S3_PREFIX_CONNECTION_LOGS_RAW=$9
    local TAGS=${10}
    local S3_PREFIX_ACCESS_LOGS=$(echo "$S3_PREFIX_ACCESS_LOGS_RAW" | xargs | sed 's:^/*::;s:/*$::') # 前後のスラッシュを削除
    local S3_PREFIX_CONNECTION_LOGS=$(echo "$S3_PREFIX_CONNECTION_LOGS_RAW" | xargs | sed 's:^/*::;s:/*$::') # 前後のスラッシュを削除

    # アクセスログ設定 (ALB/NLB共通)
    if [ "$ENABLE_ACCESS_LOGS" == "true" ]; then
        if [ -z "$S3_BUCKET_NAME_ACCESS_LOGS" ]; then
            echo " エラー: アクセスログを有効にするにはS3バケット名を指定する必要があります"
            return 1
        fi

        # S3バケットの確認と作成 (アクセスログ用)
        ensure_s3_bucket "$REGION" "$S3_BUCKET_NAME_ACCESS_LOGS" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX_ACCESS_LOGS" "$TAGS"
        if [ $? -ne 0 ]; then
            echo " エラー: アクセスログ用S3バケットの準備に失敗しました"
            return 1
        fi
        # NLBの場合、ここで明示的にバケットポリシーを設定
        if [ "$LB_TYPE" == "NLB" ]; then
            set_bucket_policy "$S3_BUCKET_NAME_ACCESS_LOGS" "$REGION" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX_ACCESS_LOGS"
            if [ $? -ne 0 ]; then
                echo " エラー: アクセスログ用S3バケットのポリシー設定に失敗しました"
                return 1
            fi
        fi

        echo " アクセスログを設定しています..."
        echo " バケット: $S3_BUCKET_NAME_ACCESS_LOGS"
        echo " プレフィックス: $S3_PREFIX_ACCESS_LOGS"

        local ATTRIBUTES=("Key=access_logs.s3.enabled,Value=true" "Key=access_logs.s3.bucket,Value=$S3_BUCKET_NAME_ACCESS_LOGS")
        if [ -n "$S3_PREFIX_ACCESS_LOGS" ]; then
            ATTRIBUTES+=("Key=access_logs.s3.prefix,Value=$S3_PREFIX_ACCESS_LOGS")
        fi

        aws elbv2 modify-load-balancer-attributes \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" \
            --attributes "${ATTRIBUTES[@]}"

        if [ $? -eq 0 ]; then
            echo " アクセスログ設定が成功しました"
        else
            echo " エラー: アクセスログ設定に失敗しました"
            return 1
        fi
    else
        echo " アクセスログは無効化されています (ENABLE_ACCESS_LOGS: $ENABLE_ACCESS_LOGS)"
    fi

    # 接続ログ設定 (ALBの場合のみ)とNLB接続ログ設定
    if [ "$LB_TYPE" == "ALB" ] && [ "$ENABLE_CONNECTION_LOGS" == "true" ]; then
        if [ -z "$S3_BUCKET_NAME_CONNECTION_LOGS" ]; then
            echo " エラー: ALB接続ログを有効にするにはS3バケット名を指定する必要があります"
            return 1
        fi

        # S3バケットの確認と作成 (接続ログ用)
        ensure_s3_bucket "$REGION" "$S3_BUCKET_NAME_CONNECTION_LOGS" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX_CONNECTION_LOGS" "$TAGS"
        if [ $? -ne 0 ]; then
            echo " エラー: ALB接続ログ用S3バケットの準備に失敗しました"
            return 1
        fi

        echo " ALB接続ログを設定しています..."
        echo " バケット: $S3_BUCKET_NAME_CONNECTION_LOGS"
        echo " プレフィックス: $S3_PREFIX_CONNECTION_LOGS"

        local ATTRIBUTES=("Key=connection_logs.s3.enabled,Value=true" "Key=connection_logs.s3.bucket,Value=$S3_BUCKET_NAME_CONNECTION_LOGS")
        if [ -n "$S3_PREFIX_CONNECTION_LOGS" ]; then
            ATTRIBUTES+=("Key=connection_logs.s3.prefix,Value=$S3_PREFIX_CONNECTION_LOGS")
        fi

        aws elbv2 modify-load-balancer-attributes \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" \
            --attributes "${ATTRIBUTES[@]}"

        if [ $? -eq 0 ]; then
            echo " ALB接続ログ設定が成功しました"
        else
            echo " エラー: ALB接続ログ設定に失敗しました"
            return 1
        fi
    elif [ "$LB_TYPE" == "ALB" ]; then
        echo " ALB接続ログは無効化されています (ENABLE_CONNECTION_LOGS: $ENABLE_CONNECTION_LOGS)"
    fi

    # NLBのアクセスログ設定
    if [ "$LB_TYPE" == "NLB" ] && [ "$ENABLE_ACCESS_LOGS" == "true" ]; then
        if [ -z "$S3_BUCKET_NAME_CONNECTION_LOGS" ]; then
            echo " エラー: NLBアクセスログを有効にするにはS3バケット名を指定する必要があります"
            return 1
        fi

        # S3バケットの確認と作成 (接続ログ用)
        ensure_s3_bucket "$REGION" "$S3_BUCKET_NAME_ACCESS_LOGS" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX_ACCESS_LOGS" "$TAGS"
        if [ $? -ne 0 ]; then
            echo " エラー: NLBアクセスログ用S3バケットの準備に失敗しました"
            return 1
        fi
        # NLBの場合、ここで明示的にバケットポリシーを設定
        set_bucket_policy "$S3_BUCKET_NAME_ACCESS_LOGS" "$REGION" "$LB_TYPE" "$LB_ARN" "$S3_PREFIX_ACCESS_LOGS"
        if [ $? -ne 0 ]; then
            echo " エラー: NLBアクセスログ用S3バケットのポリシー設定に失敗しました"
            return 1
        fi

        echo " NLBアクセスログを設定しています..."
        echo " バケット: $S3_BUCKET_NAME_CONNECTION_LOGS"
        echo " プレフィックス: $S3_PREFIX_CONNECTION_LOGS"

        local ATTRIBUTES=("Key=connection_logs.s3.enabled,Value=true" "Key=connection_logs.s3.bucket,Value=$S3_BUCKET_NAME_ACCESS_LOGS")
        if [ -n "$S3_PREFIX_CONNECTION_LOGS" ]; then
            ATTRIBUTES+=("Key=connection_logs.s3.prefix,Value=$S3_PREFIX_ACCESS_LOGS")
        fi

        aws elbv2 modify-load-balancer-attributes \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" \
            --attributes "${ATTRIBUTES[@]}"

        if [ $? -eq 0 ]; then
            echo " NLBアクセスログ設定が成功しました"
        else
            echo " エラー: NLB接続ログ設定に失敗しました"
            return 1
        fi
    elif [ "$LB_TYPE" == "NLB" ]; then
        echo " NLBアクセスログは無効化されています (ENABLE_CONNECTION_LOGS: $ENABLE_ACCESS_LOGS)"
    fi

    return 0
}

# ロードバランサーの追加属性を設定する関数
set_load_balancer_attributes() {
    local REGION=$1
    local LB_ARN=$2
    local LB_TYPE=$3
    local DELETE_PROTECTION=$4
    local IDLE_TIMEOUT=$5
    local WAF_FAIL_OPEN=$6
    local CLIENT_KEEP_ALIVE=$7
    local DESYNC_MITIGATION=$8
    local X_FORWARDED_FOR=$9
    local CLIENT_PORT_PRESERVATION=${10}
    local HOST_HEADER_PRESERVATION=${11}
    local ARC_ZONE_SHIFT=${12}
    local ROUTING_POLICY=${13}
    local TARGET_SELECTION=${14}

    local ATTRIBUTES=()

    # 共通属性
    if [ -n "$DELETE_PROTECTION" ]; then
        ATTRIBUTES+=("Key=deletion_protection.enabled,Value=$DELETE_PROTECTION")
    fi

    # ALB固有属性
    if [ "$LB_TYPE" == "ALB" ]; then
        if [ -n "$IDLE_TIMEOUT" ]; then
            ATTRIBUTES+=("Key=idle_timeout.timeout_seconds,Value=$IDLE_TIMEOUT")
        fi
        if [ -n "$WAF_FAIL_OPEN" ]; then
            ATTRIBUTES+=("Key=waf.fail_open.enabled,Value=$WAF_FAIL_OPEN")
        fi
        if [ -n "$CLIENT_KEEP_ALIVE" ]; then
            ATTRIBUTES+=("Key=client_keep_alive.seconds,Value=$CLIENT_KEEP_ALIVE")
        fi
        if [ -n "$DESYNC_MITIGATION" ]; then
            ATTRIBUTES+=("Key=routing.http.desync_mitigation_mode,Value=$DESYNC_MITIGATION")
        fi
        if [ -n "$X_FORWARDED_FOR" ]; then
            ATTRIBUTES+=("Key=routing.http.xff_header_processing.mode,Value=$X_FORWARDED_FOR")
        fi
        if [ -n "$CLIENT_PORT_PRESERVATION" ]; then
            ATTRIBUTES+=("Key=routing.http.xff_client_port.enabled,Value=$CLIENT_PORT_PRESERVATION")
        fi
        if [ -n "$HOST_HEADER_PRESERVATION" ]; then
            ATTRIBUTES+=("Key=routing.http.preserve_host_header.enabled,Value=$HOST_HEADER_PRESERVATION")
        fi
        if [ -n "$ARC_ZONE_SHIFT" ]; then
            ATTRIBUTES+=("Key=zonal_shift.config.enabled,Value=$ARC_ZONE_SHIFT")
        fi
    fi

    # NLB固有属性
    if [ "$LB_TYPE" == "NLB" ]; then
        if [ -n "$ARC_ZONE_SHIFT" ]; then
            ATTRIBUTES+=("Key=zonal_shift.config.enabled,Value=$ARC_ZONE_SHIFT")
        fi
        if [ -n "$ROUTING_POLICY" ]; then
            ATTRIBUTES+=("Key=dns_record.client_routing_policy,Value=$ROUTING_POLICY")
        fi
        if [ -n "$TARGET_SELECTION" ]; then
           ATTRIBUTES+=("Key=load_balancing.cross_zone.enabled,Value=$TARGET_SELECTION") 
        fi
    fi

    # 追加属性がある場合は設定
    if [ ${#ATTRIBUTES[@]} -gt 0 ]; then
        echo "  追加属性を設定しています..."
        aws elbv2 modify-load-balancer-attributes \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" \
            --attributes "${ATTRIBUTES[@]}"
    fi
}

# ロードバランサーを作成または更新する関数
create_or_update_load_balancer() {
    local REGION=$1
    local LB_TYPE=$2
    local LB_NAME=$3
    local VPC_ID=$4
    local SUBNET_IDS_STR=$5
    local SG_IDS_STR=$6
    local SCHEME=$7
    local IP_TYPE=$8
    local TAGS=$9
    local ENABLE_ACCESS_LOGS=${10}
    local S3_BUCKET_NAME_ACCESS_LOGS=${11}
    local S3_PREFIX_ACCESS_LOGS=${12}
    local DELETE_PROTECTION=${13}
    local IDLE_TIMEOUT=${14}
    local ENABLE_CONNECTION_LOGS=${15}
    local S3_BUCKET_NAME_CONNECTION_LOGS=${16}
    local S3_PREFIX_CONNECTION_LOGS=${17}
    local WAF_FAIL_OPEN=${18}
    local CLIENT_KEEP_ALIVE=${19}
    local DESYNC_MITIGATION=${20}
    local X_FORWARDED_FOR=${21}
    local CLIENT_PORT_PRESERVATION=${22}
    local HOST_HEADER_PRESERVATION=${23}
    local ARC_ZONE_SHIFT=${24}
    local ROUTING_POLICY=${25}
    local TARGET_SELECTION=${26}

    echo "DEBUG: 入力パラメータ"
    echo "  LB_TYPE: $LB_TYPE"
    echo "  LB_NAME: $LB_NAME"
    echo "  VPC_ID: $VPC_ID"
    echo "  SUBNET_IDS_STR: $SUBNET_IDS_STR"
    echo "  SG_IDS_STR: $SG_IDS_STR"
    echo "  SCHEME: $SCHEME"
    echo "  IP_TYPE: $IP_TYPE"
    echo "  ENABLE_ACCESS_LOGS: $ENABLE_ACCESS_LOGS"
    echo "  S3_BUCKET_NAME_ACCESS_LOGS: $S3_BUCKET_NAME_ACCESS_LOGS"
    echo "  S3_PREFIX_ACCESS_LOGS: $S3_PREFIX_ACCESS_LOGS"
    echo "  DELETE_PROTECTION: $DELETE_PROTECTION"
    echo "  IDLE_TIMEOUT: $IDLE_TIMEOUT"
    echo "  ENABLE_CONNECTION_LOGS: $ENABLE_CONNECTION_LOGS"
    echo "  S3_BUCKET_NAME_CONNECTION_LOGS: $S3_BUCKET_NAME_CONNECTION_LOGS"
    echo "  S3_PREFIX_CONNECTION_LOGS: $S3_PREFIX_CONNECTION_LOGS"
    echo "  TLS_VERSION: $TLS_VERSION"
    echo "  CIPHER_HEADER: $CIPHER_HEADER"
    echo "  WAF_FAIL_OPEN: $WAF_FAIL_OPEN"
    echo "  CLIENT_KEEP_ALIVE: $CLIENT_KEEP_ALIVE"
    echo "  DESYNC_MITIGATION: $DESYNC_MITIGATION"
    echo "  X_FORWARDED_FOR: $X_FORWARDED_FOR"
    echo "  CLIENT_PORT_PRESERVATION: $CLIENT_PORT_PRESERVATION"
    echo "  HOST_HEADER_PRESERVATION: $HOST_HEADER_PRESERVATION"
    echo "  ARC_ZONE_SHIFT: $ARC_ZONE_SHIFT"
    echo "  ROUTING_POLICY: $ROUTING_POLICY"
    echo "  TARGET_SELECTION: $TARGET_SELECTION"

    # ロードバランサー名の検証
    if [[ "$LB_NAME" == internal-* ]]; then
        echo "  エラー: ロードバランサー名 '$LB_NAME' は 'internal-' で始めることはできません"
        return 1
    fi

    # 既存のロードバランサーをチェック
    local LB_ARN=$(get_load_balancer_arn "$REGION" "$LB_NAME")

    # サブネットIDを配列に変換
    IFS=' ' read -ra SUBNET_IDS <<< "$SUBNET_IDS_STR"
    echo "DEBUG: サブネットID配陣: ${SUBNET_IDS[@]}"

    # セキュリティグループIDを配列に変換
    local SG_IDS=()
    if [ -n "$SG_IDS_STR" ]; then
        IFS=' ' read -ra SG_IDS <<< "$SG_IDS_STR"
        echo "DEBUG: セキュリティグループID配列: ${SG_IDS[@]}"
    fi

    local CREATE_ARGS=(
        --region "$REGION"
        --name "$LB_NAME"
    )

    # タイプ別のパラメータ設定
    if [ "$LB_TYPE" == "ALB" ]; then
        CREATE_ARGS+=(--type "application")
        local CURRENT_SCHEME=${SCHEME:-internet-facing}
        CREATE_ARGS+=(--scheme "$CURRENT_SCHEME")
        local CURRENT_IP_TYPE=${IP_TYPE:-ipv4}
        CREATE_ARGS+=(--ip-address-type "$CURRENT_IP_TYPE")
        # セキュリティグループ設定 (ALBのみ)
        if [ ${#SG_IDS[@]} -gt 0 ]; then
            CREATE_ARGS+=(--security-groups "${SG_IDS[@]}")
        fi
    elif [ "$LB_TYPE" == "NLB" ]; then
        CREATE_ARGS+=(--type "network")
        local CURRENT_SCHEME=${SCHEME:-internal}
        CREATE_ARGS+=(--scheme "$CURRENT_SCHEME")
        local CURRENT_IP_TYPE=${IP_TYPE:-ipv4}
        CREATE_ARGS+=(--ip-address-type "$CURRENT_IP_TYPE")
    else
        echo "  エラー: 未知のロードバランサータイプ '$LB_TYPE'"
        return 1
    fi

    # サブネット設定
    CREATE_ARGS+=(--subnets "${SUBNET_IDS[@]}")

    if [ -z "$LB_ARN" ]; then
        echo "[$REGION] $LB_TYPE ロードバランサー '$LB_NAME' の作成を開始..."
        echo "DEBUG: 実行コマンド: aws elbv2 create-load-balancer ${CREATE_ARGS[@]}"

        LB_ARN=$(aws elbv2 create-load-balancer "${CREATE_ARGS[@]}" --query "LoadBalancers[0].LoadBalancerArn" --output text)

        if [ -z "$LB_ARN" ]; then
            echo "  エラー: ロードバランサーの作成に失敗しました"
            return 1
        fi
        echo "  作成成功: ARN = $LB_ARN"

        # ロードバランサーがactive状態になるまで待機
        wait_for_load_balancer "$REGION" "$LB_ARN"
        if [ $? -ne 0 ]; then
            echo "  警告: ロードバランサーの状態確認に問題が発生しましたが、処理を続行します"
        fi

        # タグの追加
        if [ -n "$TAGS" ]; then
            echo "  タグを追加しています..."
            local TAG_ARRAY=()
            IFS=';' read -ra TAG_PAIRS <<< "$TAGS"
            for TAG_PAIR_RAW in "${TAG_PAIRS[@]}"; do
                local TAG_PAIR=$(echo "$TAG_PAIR_RAW" | xargs)
                IFS='=' read -r KEY VALUE <<< "$TAG_PAIR"
                TAG_ARRAY+=("Key=$KEY,Value=$VALUE")
            done
            aws elbv2 add-tags \
                --resource-arns "$LB_ARN" \
                --tags "${TAG_ARRAY[@]}" \
                --region "$REGION"
        fi
    else
        echo "[$REGION] 既存のロードバランサー '$LB_NAME' が見つかりました (ARN: $LB_ARN)"
    fi

    # 追加属性の設定
    set_load_balancer_attributes \
        "$REGION" \
        "$LB_ARN" \
        "$LB_TYPE" \
        "$DELETE_PROTECTION" \
        "$IDLE_TIMEOUT" \
        "$WAF_FAIL_OPEN" \
        "$CLIENT_KEEP_ALIVE" \
        "$DESYNC_MITIGATION" \
        "$X_FORWARDED_FOR" \
        "$CLIENT_PORT_PRESERVATION" \
        "$HOST_HEADER_PRESERVATION" \
        "$ARC_ZONE_SHIFT" \
        "$ROUTING_POLICY" \
        "$TARGET_SELECTION"

    # ログ設定 (アクセスログと接続ログ)
    if [ "$ENABLE_ACCESS_LOGS" == "true" ] || [ "$ENABLE_CONNECTION_LOGS" == "true" ]; then
        configure_load_balancer_logs \
            "$REGION" \
            "$LB_ARN" \
            "$LB_TYPE" \
            "$ENABLE_ACCESS_LOGS" \
            "$S3_BUCKET_NAME_ACCESS_LOGS" \
            "$S3_PREFIX_ACCESS_LOGS" \
            "$ENABLE_CONNECTION_LOGS" \
            "$S3_BUCKET_NAME_CONNECTION_LOGS" \
            "$S3_PREFIX_CONNECTION_LOGS" \
            "$TAGS"
        if [ $? -ne 0 ]; then
            echo "  警告: ログ設定に失敗しましたが、処理を続行します"
        fi
    else
        echo "  ログ設定は無効化されています"
    fi

    echo "$LB_ARN"
}

# メイン処理
{
    # ヘッダー行を読み飛ばす
    read -r header

    while IFS=, read -r REGION LB_TYPE LB_NAME VPC SUBNETS SECURITY_GROUPS SCHEME IP_TYPE TAGS \
        ENABLE_ACCESS_LOGS S3_BUCKET_NAME_ACCESS_LOGS S3_PREFIX_ACCESS_LOGS DELETE_PROTECTION IDLE_TIMEOUT \
        ENABLE_CONNECTION_LOGS S3_BUCKET_NAME_CONNECTION_LOGS S3_PREFIX_CONNECTION_LOGS \
        WAF_FAIL_OPEN CLIENT_KEEP_ALIVE DESYNC_MITIGATION X_FORWARDED_FOR \
        CLIENT_PORT_PRESERVATION HOST_HEADER_PRESERVATION ARC_ZONE_SHIFT ROUTING_POLICY TARGET_SELECTION
    do
        # 空行をスキップ
        if [ -z "$REGION" ] && [ -z "$LB_TYPE" ] && [ -z "$LB_NAME" ]; then
            continue
        fi

        echo "新しい行の処理を開始: $LB_NAME"

        # 変数の前後の空白をトリム
        REGION=$(echo "$REGION" | xargs)
        LB_TYPE=$(echo "$LB_TYPE" | xargs | tr '[:lower:]' '[:upper:]')
        LB_NAME=$(echo "$LB_NAME" | xargs)
        VPC=$(echo "$VPC" | xargs)
        SUBNETS=$(echo "$SUBNETS" | xargs)
        SECURITY_GROUPS=$(echo "$SECURITY_GROUPS" | xargs)
        SCHEME=$(echo "$SCHEME" | xargs | tr '[:upper:]' '[:lower:]')
        IP_TYPE=$(echo "$IP_TYPE" | xargs | tr '[:upper:]' '[:lower:]')
        TAGS=$(echo "$TAGS" | xargs)
        ENABLE_ACCESS_LOGS=$(echo "$ENABLE_ACCESS_LOGS" | xargs | tr '[:upper:]' '[:lower:]')
        S3_BUCKET_NAME_ACCESS_LOGS=$(echo "$S3_BUCKET_NAME_ACCESS_LOGS" | xargs)
        S3_PREFIX_ACCESS_LOGS=$(echo "$S3_PREFIX_ACCESS_LOGS" | xargs)
        DELETE_PROTECTION=$(echo "$DELETE_PROTECTION" | xargs | tr '[:upper:]' '[:lower:]')
        IDLE_TIMEOUT=$(echo "$IDLE_TIMEOUT" | xargs)
        ENABLE_CONNECTION_LOGS=$(echo "$ENABLE_CONNECTION_LOGS" | xargs | tr '[:upper:]' '[:lower:]')
        S3_BUCKET_NAME_CONNECTION_LOGS=$(echo "$S3_BUCKET_NAME_CONNECTION_LOGS" | xargs)
        S3_PREFIX_CONNECTION_LOGS=$(echo "$S3_PREFIX_CONNECTION_LOGS" | xargs)
        WAF_FAIL_OPEN=$(echo "$WAF_FAIL_OPEN" | xargs | tr '[:upper:]' '[:lower:]')
        CLIENT_KEEP_ALIVE=$(echo "$CLIENT_KEEP_ALIVE" | xargs)
        DESYNC_MITIGATION=$(echo "$DESYNC_MITIGATION" | xargs)
        X_FORWARDED_FOR=$(echo "$X_FORWARDED_FOR" | xargs)
        CLIENT_PORT_PRESERVATION=$(echo "$CLIENT_PORT_PRESERVATION" | xargs | tr '[:upper:]' '[:lower:]')
        HOST_HEADER_PRESERVATION=$(echo "$HOST_HEADER_PRESERVATION" | xargs | tr '[:upper:]' '[:lower:]')
        ARC_ZONE_SHIFT=$(echo "$ARC_ZONE_SHIFT" | xargs | tr '[:upper:]' '[:lower:]')
        ROUTING_POLICY=$(echo "$ROUTING_POLICY" | xargs)
        TARGET_SELECTION=$(echo "$TARGET_SELECTION" | xargs | tr '[:upper:]' '[:lower:]')       
 
        # 必須フィールドの検証
        if [ -z "$REGION" ] || [ -z "$LB_TYPE" ] || [ -z "$LB_NAME" ] || [ -z "$SUBNETS" ]; then
            echo "  エラー: 必須フィールド(REGION, TYPE, NAME, SUBNETS)が不足しています。この行をスキップします"
            echo "--------------------------------------------------"
            continue
        fi

        # VPC IDの解決
        RESOLVED_VPC_ID=$(get_vpc_id "$REGION" "$VPC")
        if [ $? -ne 0 ] && [ -n "$VPC" ]; then
            echo "  VPC解決に失敗したため、この行の処理をスキップします"
            echo "--------------------------------------------------"
            continue
        fi

        # サブネットIDの解決
        RESOLVED_SUBNET_IDS=$(get_subnet_ids "$REGION" "$SUBNETS")
        if [ $? -ne 0 ]; then
            echo "  サブネット解決に失敗したため、この行の処理をスキップします"
            echo "--------------------------------------------------"
            continue
        fi

        # セキュリティグループIDの解決
        RESOLVED_SG_IDS=$(get_security_group_ids "$REGION" "$SECURITY_GROUPS" "$RESOLVED_VPC_ID")
        if [ $? -ne 0 ]; then
            echo "  セキュリティグループ解決に失敗したため、この行の処理をスキップします"
            echo "--------------------------------------------------"
            continue
        fi

        # ロードバランサー作成または更新
        LB_ARN=$(create_or_update_load_balancer \
            "$REGION" \
            "$LB_TYPE" \
            "$LB_NAME" \
            "$RESOLVED_VPC_ID" \
            "$RESOLVED_SUBNET_IDS" \
            "$RESOLVED_SG_IDS" \
            "$SCHEME" \
            "$IP_TYPE" \
            "$TAGS" \
            "$ENABLE_ACCESS_LOGS" \
            "$S3_BUCKET_NAME_ACCESS_LOGS" \
            "$S3_PREFIX_ACCESS_LOGS" \
            "$DELETE_PROTECTION" \
            "$IDLE_TIMEOUT" \
            "$ENABLE_CONNECTION_LOGS" \
            "$S3_BUCKET_NAME_CONNECTION_LOGS" \
            "$S3_PREFIX_CONNECTION_LOGS" \
            "$WAF_FAIL_OPEN" \
            "$CLIENT_KEEP_ALIVE" \
            "$DESYNC_MITIGATION" \
            "$X_FORWARDED_FOR" \
            "$CLIENT_PORT_PRESERVATION" \
            "$HOST_HEADER_PRESERVATION" \
            "$ARC_ZONE_SHIFT" \
            "$ROUTING_POLICY" \
            "$TARGET_SELECTION")

        if [ -z "$LB_ARN" ]; then
            echo "--------------------------------------------------"
            continue
        fi

        echo "--------------------------------------------------"
    done
} < "$CSV_FILE"

echo "全てのロードバランサー作成処理が完了しました"
