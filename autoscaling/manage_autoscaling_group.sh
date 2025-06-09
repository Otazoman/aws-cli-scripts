#!/bin/bash

# スクリプトの利用法を表示する関数
usage() {
    echo "使用方法: $0 <csv_ファイル>"
    echo "  <csv_ファイル>  : Auto Scaling Group の設定を含むCSVファイルへのパス。"
    exit 1
}

# ターゲットグループ名またはARNからターゲットグループARNを取得する関数
get_target_group_arn() {
    local tg_identifier=$1
    local region=$2

    # デバッグメッセージは標準エラー出力に出す
    echo "デバッグ: ターゲットグループ識別子 '$tg_identifier' をリージョン '$region' で解決中..." >&2

    # 既にARN形式かどうかチェック
    if [[ "$tg_identifier" =~ ^arn:aws:elasticloadbalancing:.* ]]; then
        echo "デバッグ: ターゲットグループ識別子 '$tg_identifier' は既にARN形式です。" >&2
        echo "$tg_identifier" # これだけを標準出力に
        return 0
    fi

    echo "デバッグ: aws elbv2 describe-target-groups --names \"$tg_identifier\" --query 'TargetGroups[0].TargetGroupArn' --output text --region \"$region\" を実行します。" >&2
    
    tg_info=$(aws elbv2 describe-target-groups \
        --names "$tg_identifier" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text \
        --region "$region" 2>&1)

    echo "デバッグ: 'aws elbv2 describe-target-groups' コマンドの生出力: '$tg_info'" >&2
    
    if [[ "$tg_info" == "" ]]; then
        echo "エラー: AWS CLIターゲットグループ検索結果が空です。コマンドが失敗した可能性があります。" >&2
        return 1
    fi
    if echo "$tg_info" | grep -q "^An error occurred"; then
        echo "エラー: AWS CLIターゲットグループ検索中にエラーが発生しました: $tg_info" >&2
        return 1
    fi

    tg_arn="$tg_info" 
    echo "デバッグ: 解決されたターゲットグループARN (変数内): '$tg_arn'" >&2

    if [[ "$tg_arn" != "None" && -n "$tg_arn" ]]; then
        echo "デバッグ: ターゲットグループ名 '$tg_identifier' はARN '$tg_arn' に解決されました。" >&2
        echo "$tg_arn" # これだけを標準出力に
        return 0
    fi

    echo "エラー: リージョン '$region' でターゲットグループ名 '$tg_identifier' をARNに解決できませんでした。存在するターゲットグループ名か、正しいリージョンか確認してください。" >&2
    return 1
}

# サブネット名またはIDからサブネットIDを取得する関数
get_subnet_id() {
    local subnet_identifier=$1
    local region=$2

    # デバッグメッセージは標準エラー出力に出す
    echo "デバッグ: サブネット識別子 '$subnet_identifier' をリージョン '$region' で解決中..." >&2

    # 既にサブネットID形式かどうかチェック
    if [[ "$subnet_identifier" =~ ^subnet-[0-9a-fA-F]{8,17}$ ]]; then
        echo "デバッグ: サブネット識別子 '$subnet_identifier' は既にID形式です。" >&2
        echo "$subnet_identifier" # これだけを標準出力に
        return 0
    fi

    echo "デバッグ: aws ec2 describe-subnets --filters \"Name=tag:Name,Values=$subnet_identifier\" --query 'Subnets[0].SubnetId' --output text --region \"$region\" を実行します。" >&2
    
    subnet_info=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=$subnet_identifier" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$region" 2>&1)

    echo "デバッグ: 'aws ec2 describe-subnets' コマンドの生出力: '$subnet_info'" >&2
    
    if [[ "$subnet_info" == "" ]]; then
        echo "エラー: AWS CLIサブネット検索結果が空です。コマンドが失敗した可能性があります。" >&2
        return 1
    fi
    if echo "$subnet_info" | grep -q "^An error occurred"; then
        echo "エラー: AWS CLIサブネット検索中にエラーが発生しました: $subnet_info" >&2
        return 1
    fi

    subnet_id="$subnet_info" 
    echo "デバッグ: 解決されたサブネットID (変数内): '$subnet_id'" >&2 # これも標準エラー出力に

    if [[ "$subnet_id" != "None" && -n "$subnet_id" ]]; then
        echo "デバッグ: サブネット名 '$subnet_identifier' はID '$subnet_id' に解決されました。" >&2 # これも標準エラー出力に
        echo "$subnet_id" # これだけを標準出力に
        return 0
    fi

    echo "エラー: リージョン '$region' でサブネット名 '$subnet_identifier' をIDに解決できませんでした。存在するサブネット名か、正しいリージョンか確認してください。" >&2
    return 1
}

# CSVファイルのパスを引数から取得
CSV_FILE="$1"

# CSVファイルの検証
if [[ -z "$CSV_FILE" ]]; then
    echo "エラー: CSVファイルは必須です。"
    usage
fi

if [[ ! -f "$CSV_FILE" ]]; then
    echo "エラー: CSVファイル '$CSV_FILE' が見つかりません。"
    exit 1
fi

echo "CSVファイル: $CSV_FILE からAuto Scaling Group の設定を処理中..."
echo "----------------------------------------------------"

# CSVファイルをヘッダー行をスキップして1行ずつ読み込む
tail -n +2 "$CSV_FILE" | while IFS=, read -r ACTION REGION AUTOSCALING_GROUP_NAME LAUNCH_TEMPLATE_NAME LAUNCH_TEMPLATE_VERSION MIN_SIZE MAX_SIZE DESIRED_CAPACITY SUBNETS HEALTH_CHECK_TYPE HEALTH_CHECK_GRACE_PERIOD DEFAULT_INSTANCE_WARMUP CAPACITY_REBALANCE NEW_INSTANCES_PROTECTED_FROM_SCALE_IN MAINTENANCE_POLICY_TYPE MIN_HEALTHY_PERCENTAGE MAX_HEALTHY_PERCENTAGE TAGS TARGET_GROUP_ARNS LOAD_BALANCER_TARGET_GROUP_ARNS METRICS_GRANULARITY METRICS POLICY_NAME POLICY_TYPE TARGET_TRACKING_METRIC_TYPE TARGET_TRACKING_TARGET_VALUE DISABLE_SCALE_IN_BOOLEAN
do
    # 各変数の前後の空白をトリム
    ACTION=$(echo "$ACTION" | xargs)
    REGION=$(echo "$REGION" | xargs)
    AUTOSCALING_GROUP_NAME=$(echo "$AUTOSCALING_GROUP_NAME" | xargs)
    LAUNCH_TEMPLATE_NAME=$(echo "$LAUNCH_TEMPLATE_NAME" | xargs)
    LAUNCH_TEMPLATE_VERSION=$(echo "$LAUNCH_TEMPLATE_VERSION" | xargs)
    MIN_SIZE=$(echo "$MIN_SIZE" | xargs)
    MAX_SIZE=$(echo "$MAX_SIZE" | xargs)
    DESIRED_CAPACITY=$(echo "$DESIRED_CAPACITY" | xargs)
    SUBNETS=$(echo "$SUBNETS" | xargs) # ここが最も重要
    HEALTH_CHECK_TYPE=$(echo "$HEALTH_CHECK_TYPE" | xargs)
    HEALTH_CHECK_GRACE_PERIOD=$(echo "$HEALTH_CHECK_GRACE_PERIOD" | xargs)
    DEFAULT_INSTANCE_WARMUP=$(echo "$DEFAULT_INSTANCE_WARMUP" | xargs)
    CAPACITY_REBALANCE=$(echo "$CAPACITY_REBALANCE" | xargs)
    NEW_INSTANCES_PROTECTED_FROM_SCALE_IN=$(echo "$NEW_INSTANCES_PROTECTED_FROM_SCALE_IN" | xargs)
    MAINTENANCE_POLICY_TYPE=$(echo "$MAINTENANCE_POLICY_TYPE" | xargs)
    MIN_HEALTHY_PERCENTAGE=$(echo "$MIN_HEALTHY_PERCENTAGE" | xargs)
    MAX_HEALTHY_PERCENTAGE=$(echo "$MAX_HEALTHY_PERCENTAGE" | xargs)
    TAGS=$(echo "$TAGS" | xargs)
    TARGET_GROUP_ARNS=$(echo "$TARGET_GROUP_ARNS" | xargs)
    LOAD_BALANCER_TARGET_GROUP_ARNS=$(echo "$LOAD_BALANCER_TARGET_GROUP_ARNS" | xargs)
    METRICS_GRANULARITY=$(echo "$METRICS_GRANULARITY" | xargs)
    METRICS=$(echo "$METRICS" | xargs)
    POLICY_NAME=$(echo "$POLICY_NAME" | xargs)
    POLICY_TYPE=$(echo "$POLICY_TYPE" | xargs)
    TARGET_TRACKING_METRIC_TYPE=$(echo "$TARGET_TRACKING_METRIC_TYPE" | xargs)
    TARGET_TRACKING_TARGET_VALUE=$(echo "$TARGET_TRACKING_TARGET_VALUE" | xargs)
    DISABLE_SCALE_IN_BOOLEAN=$(echo "$DISABLE_SCALE_IN_BOOLEAN" | xargs)

    # リージョンが空の場合はスキップ
    if [[ -z "$REGION" ]]; then
        echo "警告: Auto Scaling Group '$AUTOSCALING_GROUP_NAME' (またはその行) のリージョンが指定されていません。この行をスキップします。"
        continue
    fi

    echo "----------------------------------------------------"
    echo "アクション: $ACTION"
    echo "Auto Scaling Group 名: $AUTOSCALING_GROUP_NAME"
    echo "対象リージョン: $REGION"

    # InstanceMaintenancePolicy JSONの生成
    LOCAL_INSTANCE_MAINTENANCE_POLICY=""
    case "$MAINTENANCE_POLICY_TYPE" in
        "None" | "")
            LOCAL_INSTANCE_MAINTENANCE_POLICY=""
            ;;
        "LaunchBeforeTerminate")
            # MaxHealthyPercentage を可変にする
            if [[ -n "$MAX_HEALTHY_PERCENTAGE" ]]; then
                LOCAL_INSTANCE_MAINTENANCE_POLICY="{\"MinHealthyPercentage\": 100, \"MaxHealthyPercentage\": $MAX_HEALTHY_PERCENTAGE}"
            else
                echo "警告: 'LaunchBeforeTerminate' が選択されていますが、MaxHealthyPercentage が指定されていません。デフォルト値として MaxHealthyPercentage: 110 を使用します。"
                LOCAL_INSTANCE_MAINTENANCE_POLICY="{\"MinHealthyPercentage\": 100, \"MaxHealthyPercentage\": 110}"
            fi
            ;;
        "TerminateBeforeLaunch")
            # MinHealthyPercentage を可変にする
            if [[ -n "$MIN_HEALTHY_PERCENTAGE" ]]; then
                LOCAL_INSTANCE_MAINTENANCE_POLICY="{\"MinHealthyPercentage\": $MIN_HEALTHY_PERCENTAGE, \"MaxHealthyPercentage\": 100}"
            else
                echo "警告: 'TerminateBeforeLaunch' が選択されていますが、MinHealthyPercentage が指定されていません。デフォルト値として MinHealthyPercentage: 90 を使用します。"
                LOCAL_INSTANCE_MAINTENANCE_POLICY="{\"MinHealthyPercentage\": 90, \"MaxHealthyPercentage\": 100}"
            fi
            ;;
        "Custom")
            if [[ -n "$MIN_HEALTHY_PERCENTAGE" && -n "$MAX_HEALTHY_PERCENTAGE" ]]; then
                LOCAL_INSTANCE_MAINTENANCE_POLICY="{\"MinHealthyPercentage\": $MIN_HEALTHY_PERCENTAGE, \"MaxHealthyPercentage\": $MAX_HEALTHY_PERCENTAGE}"
            else
                echo "警告: 'Custom' が選択されていますが、MinHealthyPercentage または MaxHealthyPercentage が指定されていません。メンテナンスポリシーは設定されません。"
            fi
            ;;
        *)
            echo "警告: 不明なメンテナンスポリシータイプ '$MAINTENANCE_POLICY_TYPE' です。メンテナンスポリシーは設定されません。"
            ;;
    esac

    # DisableScaleIn のブール値を 'true'/'false' に変換
    LOCAL_DISABLE_SCALE_IN="false"
    if [[ "$(echo "$DISABLE_SCALE_IN_BOOLEAN" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
        LOCAL_DISABLE_SCALE_IN="true"
    fi

    if [[ "$ACTION" == "add" ]]; then
        echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' の作成/設定を試行中..."

        # 起動テンプレート引数の構築
        LAUNCH_TEMPLATE_ARGS="LaunchTemplateName=${LAUNCH_TEMPLATE_NAME}"
        if [[ -n "$LAUNCH_TEMPLATE_VERSION" ]]; then
            LAUNCH_TEMPLATE_ARGS="${LAUNCH_TEMPLATE_ARGS},Version=${LAUNCH_TEMPLATE_VERSION}"
        else
            LAUNCH_TEMPLATE_ARGS="${LAUNCH_TEMPLATE_ARGS},Version=\$Latest" # 指定がない場合は最新バージョンを使用
        fi

        # サブネットの解決
        VPC_ZONE_IDENTIFIER=""
        SUBNETS_RESOLVED_OK=true
        ADDR=(${SUBNETS//;/ })
        for i in "${ADDR[@]}"; do
            if [[ -z "$i" ]]; then # 空のサブネット識別子をスキップ
                continue
            fi
            SUBNET_ID=$(get_subnet_id "$i" "$REGION")
            if [[ $? -ne 0 ]]; then
                echo "サブネット解決エラー: '$i' の解決に失敗しました。このASGの作成をスキップします。"
                SUBNETS_RESOLVED_OK=false
                break # 1つでも解決に失敗したらループを抜ける
            fi
            if [[ -z "$VPC_ZONE_IDENTIFIER" ]]; then
                VPC_ZONE_IDENTIFIER="$SUBNET_ID"
            else
                VPC_ZONE_IDENTIFIER="${VPC_ZONE_IDENTIFIER},${SUBNET_ID}"
            fi
        done

        if [[ "$SUBNETS_RESOLVED_OK" == "false" || -z "$VPC_ZONE_IDENTIFIER" ]]; then
            echo "エラー: サブネットの解決に失敗したか、指定されたサブネットがありません。Auto Scaling Group '$AUTOSCALING_GROUP_NAME' の作成をスキップします。"
            continue # CSVの次の行へスキップ
        fi
        echo "デバッグ: 解決されたVPCZoneIdentifier: '$VPC_ZONE_IDENTIFIER'"


        # タグの構築（ASG作成時に適用）
        TAGS_ARGS=""
        if [[ -n "$TAGS" ]]; then
            # セミコロンで分割
            IFS=';' read -ra TAG_PARTS <<< "$TAGS"
            for tag_part in "${TAG_PARTS[@]}"; do
                # タグ部分をキー、値、PropagateAtLaunchに分解
                if [[ "$tag_part" =~ ^([^=]+)=([^=]+)(,PropagateAtLaunch=(true|false))?$ ]]; then
                    tag_key="${BASH_REMATCH[1]}"
                    tag_value="${BASH_REMATCH[2]}"
                    propagate_at_launch="${BASH_REMATCH[4]:-true}"  # デフォルトはtrue
                    
                    # タグパラメータを作成（ASG作成時に使用する形式）
                    if [[ -z "$TAGS_ARGS" ]]; then
                        TAGS_ARGS="--tags Key=${tag_key},Value=${tag_value},PropagateAtLaunch=${propagate_at_launch}"
                    else
                        TAGS_ARGS="$TAGS_ARGS Key=${tag_key},Value=${tag_value},PropagateAtLaunch=${propagate_at_launch}"
                    fi
                else
                    echo "警告: 不正なタグ形式 '$tag_part' です。正しい形式は 'Key=Value' または 'Key=Value,PropagateAtLaunch=true|false' です。このタグをスキップします。"
                fi
            done
        fi


        # create-auto-scaling-group コマンドの構築
        CREATE_ASG_CMD="aws autoscaling create-auto-scaling-group"
        CREATE_ASG_CMD+=" --region \"$REGION\""
        CREATE_ASG_CMD+=" --auto-scaling-group-name \"$AUTOSCALING_GROUP_NAME\""
        CREATE_ASG_CMD+=" --launch-template \"$LAUNCH_TEMPLATE_ARGS\""
        CREATE_ASG_CMD+=" --min-size $MIN_SIZE"
        CREATE_ASG_CMD+=" --max-size $MAX_SIZE"
        CREATE_ASG_CMD+=" --desired-capacity $DESIRED_CAPACITY"
        CREATE_ASG_CMD+=" --vpc-zone-identifier \"$VPC_ZONE_IDENTIFIER\""

        if [[ $(echo "$CAPACITY_REBALANCE" | tr '[:upper:]' '[:lower:]') == "true" ]]; then
            CREATE_ASG_CMD+=" --capacity-rebalance"
        fi

        if [[ -n "$DEFAULT_INSTANCE_WARMUP" ]]; then
            CREATE_ASG_CMD+=" --default-instance-warmup $DEFAULT_INSTANCE_WARMUP"
        fi

        # ヘルスチェックオプション
        if [[ -n "$HEALTH_CHECK_TYPE" ]]; then
            CREATE_ASG_CMD+=" --health-check-type $HEALTH_CHECK_TYPE"
        fi
        if [[ -n "$HEALTH_CHECK_GRACE_PERIOD" ]]; then
            CREATE_ASG_CMD+=" --health-check-grace-period $HEALTH_CHECK_GRACE_PERIOD"
        fi

        if [[ -n "$LOCAL_INSTANCE_MAINTENANCE_POLICY" ]]; then
            CREATE_ASG_CMD+=" --instance-maintenance-policy '$LOCAL_INSTANCE_MAINTENANCE_POLICY'"
            echo "設定されるメンテナンスポリシー: $LOCAL_INSTANCE_MAINTENANCE_POLICY"
        fi

        if [[ "$(echo "$NEW_INSTANCES_PROTECTED_FROM_SCALE_IN" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
            CREATE_ASG_CMD+=" --new-instances-protected-from-scale-in"
        fi

        if [[ -n "$TAGS_ARGS" ]]; then
            CREATE_ASG_CMD+=" ${TAGS_ARGS}"
        fi

        # ロードバランサーへのアタッチ (ALB/NLB ターゲットグループ)
        # --load-balancer-target-group-arns は非推奨のため使用しない
        if [[ -n "$TARGET_GROUP_ARNS" ]]; then
            # 空白のみのTARGET_GROUP_ARNSを避けるため、トリムしてからチェック
            CLEAN_TARGET_GROUP_ARNS=$(echo "$TARGET_GROUP_ARNS" | xargs)
            if [[ -n "$CLEAN_TARGET_GROUP_ARNS" ]]; then
                # ターゲットグループが名前で指定されている場合はARNに解決する
                RESOLVED_TARGET_GROUP_ARNS=""
                TGARNS_RESOLVED_OK=true
                IFS=';' read -ra TG_PARTS <<< "$CLEAN_TARGET_GROUP_ARNS"
                for tg_part in "${TG_PARTS[@]}"; do
                    if [[ -z "$tg_part" ]]; then # 空のターゲットグループ識別子をスキップ
                        continue
                    fi
                    TG_ARN=$(get_target_group_arn "$tg_part" "$REGION")
                    if [[ $? -ne 0 ]]; then
                        echo "ターゲットグループ解決エラー: '$tg_part' の解決に失敗しました。"
                        TGARNS_RESOLVED_OK=false
                        break # 1つでも解決に失敗したらループを抜ける
                    fi
                    if [[ -z "$RESOLVED_TARGET_GROUP_ARNS" ]]; then
                        RESOLVED_TARGET_GROUP_ARNS="$TG_ARN"
                    else
                        RESOLVED_TARGET_GROUP_ARNS="${RESOLVED_TARGET_GROUP_ARNS},${TG_ARN}"
                    fi
                done
                
                if [[ "$TGARNS_RESOLVED_OK" == "true" && -n "$RESOLVED_TARGET_GROUP_ARNS" ]]; then
                    echo "デバッグ: 解決されたターゲットグループARN: '$RESOLVED_TARGET_GROUP_ARNS'"
                    CREATE_ASG_CMD+=" --target-group-arns \"$RESOLVED_TARGET_GROUP_ARNS\""
                else
                    echo "警告: ターゲットグループの解決に失敗しました。ターゲットグループの設定をスキップします。"
                fi
            fi
        fi

        # ASG作成コマンドの実行
        echo "実行コマンド: $CREATE_ASG_CMD"
        eval "$CREATE_ASG_CMD"
        if [[ $? -ne 0 ]]; then
            echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' の作成中にエラーが発生しました。"
            continue
        else
            echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' を正常に作成しました。"
        fi

        # メトリクスの設定
        if [[ -n "$METRICS_GRANULARITY" && -n "$METRICS" ]]; then
            echo "'$AUTOSCALING_GROUP_NAME' のメトリクス収集を有効化中..."
            aws autoscaling enable-metrics-collection \
                --auto-scaling-group-name "$AUTOSCALING_GROUP_NAME" \
                --granularity "$METRICS_GRANULARITY" \
                --metrics $METRICS \
                --region "$REGION"
            if [[ $? -ne 0 ]]; then
                echo "'$AUTOSCALING_GROUP_NAME' のメトリクス収集の有効化中にエラーが発生しました。"
            else
                echo "メトリクス収集を有効化しました。"
            fi
        fi

        # スケーリングポリシーの設定
        if [[ -n "$POLICY_NAME" && -n "$POLICY_TYPE" ]]; then
            echo "'$AUTOSCALING_GROUP_NAME' のスケーリングポリシーを設定中..."
            SCALING_POLICY_CONFIG=""
            if [[ "$POLICY_TYPE" == "TargetTrackingScaling" ]]; then
                SCALING_POLICY_CONFIG="{
                    \"PredefinedMetricSpecification\": {
                        \"PredefinedMetricType\": \"$TARGET_TRACKING_METRIC_TYPE\"
                    },
                    \"TargetValue\": $TARGET_TRACKING_TARGET_VALUE,
                    \"DisableScaleIn\": $LOCAL_DISABLE_SCALE_IN
                }"
                aws autoscaling put-scaling-policy \
                    --policy-name "$POLICY_NAME" \
                    --auto-scaling-group-name "$AUTOSCALING_GROUP_NAME" \
                    --policy-type "$POLICY_TYPE" \
                    --target-tracking-configuration "$SCALING_POLICY_CONFIG" \
                    --region "$REGION"
            # 必要であれば、他のポリシータイプ (例: SimpleScaling, StepScaling) をここに追加
            else
                echo "警告: 未サポートのポリシータイプ '$POLICY_TYPE' です。スケーリングポリシーの設定をスキップします。"
            fi

            if [[ $? -ne 0 ]]; then
                echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' のスケーリングポリシー '$POLICY_NAME' の設定中にエラーが発生しました。"
            else
                echo "スケーリングポリシー '$POLICY_NAME' を設定しました。"
            fi
        fi

    elif [[ "$ACTION" == "remove" ]]; then
        echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' の削除を試行中..."
        aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name "$AUTOSCALING_GROUP_NAME" \
            --force-delete \
            --region "$REGION"
        if [[ $? -ne 0 ]]; then
            echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' の削除中にエラーが発生しました。"
        else
            echo "Auto Scaling Group '$AUTOSCALING_GROUP_NAME' を正常に削除しました。"
        fi
    else
        echo "不明なアクション: '$ACTION' です。このエントリをスキップします。"
    fi
done

echo "----------------------------------------------------"
echo "スクリプトの実行が完了しました。"
