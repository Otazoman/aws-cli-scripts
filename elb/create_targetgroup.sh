#!/bin/bash

# 引数チェック
if [ $# -eq 0 ]; then
    echo "エラー: CSVファイルを引数として指定してください"
    echo "使用例: $0 targetgroups.csv"
    exit 1
fi

CSV_FILE="$1"

# CSVファイル存在チェック
if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: 指定されたCSVファイルが見つかりません: $CSV_FILE"
    exit 1
fi

echo "ターゲットグループ作成処理を開始します..."
echo "使用するCSVファイル: $CSV_FILE"
echo "--------------------------------------------------"

# VPC名またはIDからVPC IDを取得する関数
get_vpc_id() {
    local REGION=$1
    local VPC_IDENTIFIER=$2
    
    # 空の場合は空を返す（Lambdaターゲットグループなど）
    if [ -z "$VPC_IDENTIFIER" ]; then
        echo ""
        return 0
    fi
    
    # VPC ID形式 (vpc-xxxxxxxx) かどうか確認
    if [[ $VPC_IDENTIFIER == vpc-* ]]; then
        echo "$VPC_IDENTIFIER"
        return 0
    fi
    
    # VPC名からVPC IDを検索
    echo "  VPC名 '$VPC_IDENTIFIER' からVPC IDを検索..." >&2
    local VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$VPC_IDENTIFIER" \
        --query "Vpcs[0].VpcId" \
        --output text \
        --region "$REGION")
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        echo "  エラー: VPC '$VPC_IDENTIFIER' が見つかりません" >&2
        return 1
    fi
    
    echo "$VPC_ID"
}

# ターゲットグループを作成する関数
create_target_group() {
    local REGION=$1
    local VPC_ID=$2
    local TG_NAME=$3
    local TG_PROTOCOL=$4
    local TG_PORT=$5
    local HEALTH_PATH=$6
    local HEALTH_PORT=$7
    local HEALTH_PROTOCOL=$8
    local HEALTH_INTERVAL=$9
    local HEALTH_TIMEOUT=${10}
    local HEALTHY_THRESHOLD=${11}
    local UNHEALTHY_THRESHOLD=${12}
    local TARGET_TYPE=${13}
    local TARGETS=${14}
    local TARGET_PORT=${15}
    local TAGS=${16}

    echo "[$REGION] ターゲットグループ '$TG_NAME' (タイプ: $TARGET_TYPE) の作成を開始..."

    # ターゲットグループ作成パラメータの基本設定
    local CREATE_ARGS=(
        --name "$TG_NAME"
        --target-type "$TARGET_TYPE"
        --region "$REGION"
    )

    # ターゲットタイプに応じたパラメータ設定
    case $TARGET_TYPE in
        "instance"|"ip")
            if [ -z "$VPC_ID" ]; then
                echo "  エラー: $TARGET_TYPEタイプにはVPC_IDの指定が必須です"
                return 1
            fi
            
            CREATE_ARGS+=(
                --protocol "$TG_PROTOCOL"
                --port "$TG_PORT"
                --vpc-id "$VPC_ID"
                --health-check-path "$HEALTH_PATH"
                --health-check-port "$HEALTH_PORT"
                --health-check-protocol "$HEALTH_PROTOCOL"
                --health-check-interval-seconds "$HEALTH_INTERVAL"
                --health-check-timeout-seconds "$HEALTH_TIMEOUT"
                --healthy-threshold-count "$HEALTHY_THRESHOLD"
                --unhealthy-threshold-count "$UNHEALTHY_THRESHOLD"
            )
            ;;
        "lambda")
            # Lambdaの場合はヘルスチェックパスが必須
            if [ -z "$HEALTH_PATH" ]; then
                HEALTH_PATH="/"
            fi
            CREATE_ARGS+=(
                --health-check-path "$HEALTH_PATH"
            )
            ;;
        "alb")
            if [ -z "$VPC_ID" ]; then
                echo "  エラー: ALBタイプにはVPC_IDの指定が必須です"
                return 1
            fi
            # ALBの場合はプロトコルをTCPに強制
            CREATE_ARGS+=(
                --protocol "TCP"
                --port "$TG_PORT"
                --vpc-id "$VPC_ID"
            )
            ;;
        *)
            echo "  エラー: 未知のターゲットタイプ '$TARGET_TYPE'"
            return 1
            ;;
    esac

    # ターゲットグループの作成
    echo "  ターゲットグループを作成しています..."
    local TG_ARN=$(aws elbv2 create-target-group "${CREATE_ARGS[@]}" --query "TargetGroups[0].TargetGroupArn" --output text)

    if [ -z "$TG_ARN" ]; then
        echo "  エラー: ターゲットグループの作成に失敗しました"
        return 1
    fi

    echo "  作成成功: ARN = $TG_ARN"

    # タグの追加
    if [ -n "$TAGS" ]; then
        echo "  タグを追加しています..."
        local TAG_ARRAY=()
        IFS=';' read -ra TAG_PAIRS <<< "$TAGS"
        for TAG_PAIR in "${TAG_PAIRS[@]}"; do
            IFS='=' read -r KEY VALUE <<< "$TAG_PAIR"
            TAG_ARRAY+=("Key=$KEY,Value=$VALUE")
        done
        
        aws elbv2 add-tags \
            --resource-arns "$TG_ARN" \
            --tags "${TAG_ARRAY[@]}" \
            --region "$REGION"
    fi

    # ターゲットの登録
    if [ -n "$TARGETS" ]; then
        register_targets "$REGION" "$TG_ARN" "$TARGET_TYPE" "$TARGETS" "${TARGET_PORT:-$TG_PORT}"
    else
        echo "  ターゲットは空欄のため、登録をスキップします"
    fi
}

# ターゲットを登録する関数
register_targets() {
    local REGION=$1
    local TG_ARN=$2
    local TARGET_TYPE=$3
    local TARGETS=$4
    local DEFAULT_PORT=$5

    echo "  ターゲットを登録しています..."
    case $TARGET_TYPE in
        "instance")
            IFS=';' read -ra TARGET_LIST <<< "$TARGETS"
            for TARGET in "${TARGET_LIST[@]}"; do
                TARGET=$(echo "$TARGET" | xargs)
                if [ -n "$TARGET" ]; then
                    # インスタンス名の場合、インスタンスIDを解決
                    if [[ "$TARGET" != i-* ]]; then
                        echo "  インスタンス名 '$TARGET' からインスタンスIDを検索..."
                        local INSTANCE_ID=$(aws ec2 describe-instances \
                            --filters "Name=tag:Name,Values=$TARGET" \
                            --query "Reservations[0].Instances[0].InstanceId" \
                            --output text \
                            --region "$REGION")
                        if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
                            echo "  エラー: インスタンス名 '$TARGET' が見つかりません"
                            continue
                        fi
                        TARGET="$INSTANCE_ID"
                    fi
                    echo "    インスタンス $TARGET を登録 (ポート: $DEFAULT_PORT)"
                    aws elbv2 register-targets \
                        --target-group-arn "$TG_ARN" \
                        --targets "Id=$TARGET,Port=$DEFAULT_PORT" \
                        --region "$REGION" || echo "    登録に失敗しました"
                fi
            done
            ;;
        "ip")
            IFS=';' read -ra TARGET_LIST <<< "$TARGETS"
            for TARGET in "${TARGET_LIST[@]}"; do
                TARGET=$(echo "$TARGET" | xargs)
                if [ -n "$TARGET" ]; then
                    echo "    IPアドレス $TARGET を登録 (ポート: $DEFAULT_PORT)"
                    aws elbv2 register-targets \
                        --target-group-arn "$TG_ARN" \
                        --targets "Id=$TARGET,Port=$DEFAULT_PORT" \
                        --region "$REGION" || echo "    登録に失敗しました"
                fi
            done
            ;;
        "lambda")
            echo "    Lambda関数 $TARGETS を登録"
            local FUNCTION_ARN=$(aws lambda get-function --function-name "$TARGETS" --query "Configuration.FunctionArn" --output text --region "$REGION")
            if [ -n "$FUNCTION_ARN" ]; then
                aws lambda add-permission \
                    --function-name "$TARGETS" \
                    --statement-id "elbv2-access-$(date +%s)" \
                    --principal "elasticloadbalancing.amazonaws.com" \
                    --action "lambda:InvokeFunction" \
                    --source-arn "$TG_ARN" \
                    --region "$REGION"
                
                aws elbv2 register-targets \
                    --target-group-arn "$TG_ARN" \
                    --targets "Id=$FUNCTION_ARN" \
                    --region "$REGION" || echo "    登録に失敗しました"
            else
                echo "    エラー: Lambda関数が見つかりませんでした"
            fi
            ;;
        "alb")
            echo "    ALB $TARGETS を登録"
            local ALB_ARN=$(aws elbv2 describe-load-balancers --names "$TARGETS" --query "LoadBalancers[0].LoadBalancerArn" --output text --region "$REGION")
            if [ -n "$ALB_ARN" ]; then
                aws elbv2 register-targets \
                    --target-group-arn "$TG_ARN" \
                    --targets "Id=$ALB_ARN" \
                    --region "$REGION" || echo "    登録に失敗しました"
            else
                echo "    エラー: ALBが見つかりませんでした"
            fi
            ;;
    esac
}

# メイン処理
{
    # ヘッダー行を読み飛ばす
    read -r header
    
    while IFS=, read -r REGION VPC_ID TG_NAME TG_PROTOCOL TG_PORT HEALTH_PATH HEALTH_PORT HEALTH_PROTOCOL HEALTH_INTERVAL HEALTH_TIMEOUT HEALTHY_THRESHOLD UNHEALTHY_THRESHOLD TARGET_TYPE TARGETS TARGET_PORT TAGS
    do
        # 変数の前後の空白をトリム
        REGION=$(echo "$REGION" | xargs)
        VPC_ID=$(echo "$VPC_ID" | xargs)
        TG_NAME=$(echo "$TG_NAME" | xargs)
        TG_PROTOCOL=$(echo "$TG_PROTOCOL" | xargs)
        TG_PORT=$(echo "$TG_PORT" | xargs)
        TARGET_TYPE=$(echo "$TARGET_TYPE" | xargs)
        TARGETS=$(echo "$TARGETS" | xargs)
        TARGET_PORT=$(echo "$TARGET_PORT" | xargs)
        TAGS=$(echo "$TAGS" | xargs)

        # VPC IDの解決
        RESOLVED_VPC_ID=$(get_vpc_id "$REGION" "$VPC_ID")
        if [ $? -ne 0 ] && [ -n "$VPC_ID" ]; then
            continue
        fi

        create_target_group \
            "$REGION" \
            "$RESOLVED_VPC_ID" \
            "$TG_NAME" \
            "$TG_PROTOCOL" \
            "$TG_PORT" \
            "$HEALTH_PATH" \
            "$HEALTH_PORT" \
            "$HEALTH_PROTOCOL" \
            "$HEALTH_INTERVAL" \
            "$HEALTH_TIMEOUT" \
            "$HEALTHY_THRESHOLD" \
            "$UNHEALTHY_THRESHOLD" \
            "$TARGET_TYPE" \
            "$TARGETS" \
            "$TARGET_PORT" \
            "$TAGS"

        echo "--------------------------------------------------"
    done
} < "$CSV_FILE"

echo "全てのターゲットグループ作成処理が完了しました"
