#!/bin/bash

# エラー時にスクリプトを終了
set -e

# ヘルパー関数: リソースIDを取得
# 引数1: リソースタイプ (subnet, securitygroup, targetgroup)
# 引数2: 識別子 (IDまたはName)
# 引数3: リージョン
get_resource_id() {
    local resource_type="$1"
    local identifier="$2"
    local region="$3"
    local resource_id=""

    if [[ -z "$identifier" ]]; then
        echo "Error: Identifier for $resource_type cannot be empty." >&2
        return 1
    fi

    case "$resource_type" in
        "subnet")
            if [[ "$identifier" =~ ^subnet- ]]; then
                resource_id="$identifier"
            else
                resource_id=$(aws ec2 describe-subnets --region "$region" --filters "Name=tag:Name,Values=$identifier" --query 'Subnets[0].SubnetId' --output text --no-cli-pager 2>/dev/null || echo "ERROR")
            fi
            ;;
        "securitygroup")
            if [[ "$identifier" =~ ^sg- ]]; then
                resource_id="$identifier"
            else
                resource_id=$(aws ec2 describe-security-groups --region "$region" --filters "Name=group-name,Values=$identifier" --query 'SecurityGroups[0].GroupId' --output text --no-cli-pager 2>/dev/null || echo "ERROR")
            fi
            ;;
        "targetgroup")
            if [[ "$identifier" =~ ^arn:aws:elasticloadbalancing: ]]; then
                resource_id="$identifier"
            else
                resource_id=$(aws elbv2 describe-target-groups --region "$region" --names "$identifier" --query 'TargetGroups[0].TargetGroupArn' --output text --no-cli-pager 2>/dev/null || echo "ERROR")
            fi
            ;;
        *)
            echo "Error: Unknown resource type: $resource_type" >&2
            return 1
            ;;
    esac

    if [[ -z "$resource_id" || "$resource_id" == "None" || "$resource_id" == "ERROR" ]]; then
        echo "Error: Could not find $resource_type with identifier: '$identifier' in region $region" >&2
        return 1
    fi
    echo "$resource_id"
}

# CSVファイル名の確認
if [[ -z "$1" ]]; then
    echo "Usage: $0 <csv_file_path>"
    exit 1
fi

CSV_FILE="$1"

# CSVファイルのヘッダー行をスキップして各行を処理
tail -n +2 "$CSV_FILE" | while IFS=',' read -r \
    REGION \
    CLUSTER_NAME \
    TASK_DEFINITION_NAME \
    SERVICE_NAME \
    LAUNCH_TYPE \
    DESIRED_COUNT \
    SUBNETS_INPUT \
    SECURITY_GROUPS_INPUT \
    PUBLIC_IP \
    TARGET_GROUP_INPUT \
    CONTAINER_NAME \
    CONTAINER_PORT \
    HEALTH_CHECK_PERIOD \
    MIN_CAPACITY \
    MAX_CAPACITY \
    TARGET_VALUE \
    OUT_COOLDOWN \
    IN_COOLDOWN \
    TAGS_STR \
    _unused # 余分な列を吸収するためのダミー変数
do
    # 空行のスキップ (末尾に空行がある場合など)
    if [[ -z "$REGION" ]]; then
        continue
    fi

    echo "--- Processing service: ${SERVICE_NAME} in region: ${REGION} ---"

    # サブネットIDの解決
    SUBNET_IDS_ARRAY=()
    IFS=';' read -ra ADDR <<< "$SUBNETS_INPUT"
    for i in "${ADDR[@]}"; do
        i=$(echo "$i" | xargs) # 前後の空白をトリム
        if [[ -z "$i" ]]; then continue; fi # 空の要素はスキップ
        subnet_id=$(get_resource_id "subnet" "$i" "$REGION")
        if [[ $? -ne 0 ]]; then
            echo "Skipping service ${SERVICE_NAME} due to subnet resolution error."
            continue 2 # whileループの次のイテレーションへ
        fi
        SUBNET_IDS_ARRAY+=("$(printf '%q' "$subnet_id")") # シェルセーフに引用符付け
    done
    SUBNET_IDS=$(IFS=','; echo "${SUBNET_IDS_ARRAY[*]}")


    # セキュリティグループIDの解決
    SECURITY_GROUP_IDS_ARRAY=()
    IFS=';' read -ra ADDR <<< "$SECURITY_GROUPS_INPUT"
    for i in "${ADDR[@]}"; do
        i=$(echo "$i" | xargs) # 前後の空白をトリム
        if [[ -z "$i" ]]; then continue; fi # 空の要素はスキップ
        sg_id=$(get_resource_id "securitygroup" "$i" "$REGION")
        if [[ $? -ne 0 ]]; then
            echo "Skipping service ${SERVICE_NAME} due to security group resolution error."
            continue 2 # whileループの次のイテレーションへ
        fi
        SECURITY_GROUP_IDS_ARRAY+=("$(printf '%q' "$sg_id")") # シェルセーフに引用符付け
    done
    SECURITY_GROUP_IDS=$(IFS=','; echo "${SECURITY_GROUP_IDS_ARRAY[*]}")

    # awsvpcConfigurationの整形 (二重引用符はaws cliが内部で処理するので不要)
    NETWORK_CONF="awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SECURITY_GROUP_IDS}],assignPublicIp=${PUBLIC_IP}}"

    # ターゲットグループARNの解決
    TARGET_GROUP_ARN=$(get_resource_id "targetgroup" "$TARGET_GROUP_INPUT" "$REGION")
    if [[ $? -ne 0 ]]; then
        echo "Skipping service ${SERVICE_NAME} due to target group resolution error."
        continue # whileループの次のイテレーションへ
    fi

    # ロードバランサーのJSON形式を修正 (プロパティ名を二重引用符で囲む)
    LOADBALANCERS="[{\"targetGroupArn\": \"${TARGET_GROUP_ARN}\",\"containerName\":\"${CONTAINER_NAME}\",\"containerPort\":${CONTAINER_PORT}}]"


    # ヘルスチェック間隔のデフォルト値設定
    if [[ -z "$HEALTH_CHECK_PERIOD" ]]; then
        HEALTH_CHECK_PERIOD=60
    fi

    # タグの整形
    TAGS_CLI_ARG=""
    if [[ -n "$TAGS_STR" ]]; then
        IFS=';' read -ra TAG_PAIRS <<< "$TAGS_STR"
        for PAIR in "${TAG_PAIRS[@]}"; do
            PAIR=$(echo "$PAIR" | xargs) # 前後の空白をトリム
            if [[ "$PAIR" =~ ":" ]]; then
                KEY=$(echo "$PAIR" | cut -d':' -f1 | xargs)
                VALUE=$(echo "$PAIR" | cut -d':' -f2- | xargs)
                TAGS_CLI_ARG+="key=${KEY},value=${VALUE} " # 小文字のkey, valueに修正
            else
                echo "Warning: Invalid tag format '$PAIR'. Expected 'Key:Value'. Skipping this tag for service ${SERVICE_NAME}." >&2
            fi
        done
        TAGS_CLI_ARG="--tags $(echo "$TAGS_CLI_ARG" | xargs)"
    fi

    # ECS サービス作成コマンド
    echo -e "\n--- Creating ECS Service for ${SERVICE_NAME} ---"
    # コマンド文字列を生成して表示
    CREATE_SERVICE_CMD="aws ecs create-service \
      --region \"$REGION\" \
      --no-cli-pager \
      --cluster \"$CLUSTER_NAME\" \
      --service-name \"$SERVICE_NAME\" \
      --task-definition \"$TASK_DEFINITION_NAME\" \
      --desired-count \"$DESIRED_COUNT\" \
      --launch-type \"$LAUNCH_TYPE\" \
      --network-configuration \"$NETWORK_CONF\" \
      --load-balancers '$LOADBALANCERS' \
      --health-check-grace-period-seconds \"$HEALTH_CHECK_PERIOD\"" # $LOADBALANCERS を一重引用符で囲む
    
    if [[ -n "$TAGS_CLI_ARG" ]]; then
        CREATE_SERVICE_CMD+=" $TAGS_CLI_ARG"
    fi
    echo "$CREATE_SERVICE_CMD" # ★ここがコマンド表示のために追加された行

    set +e # コマンド失敗時にスクリプトを終了させない
    # コマンドを実行
    aws ecs create-service \
      --region "$REGION" \
      --no-cli-pager \
      --cluster "$CLUSTER_NAME" \
      --service-name "$SERVICE_NAME" \
      --task-definition "$TASK_DEFINITION_NAME" \
      --desired-count "$DESIRED_COUNT" \
      --launch-type "$LAUNCH_TYPE" \
      --network-configuration "$NETWORK_CONF" \
      --load-balancers "$LOADBALANCERS" \
      --health-check-grace-period-seconds "$HEALTH_CHECK_PERIOD" \
      $TAGS_CLI_ARG
    CREATE_SERVICE_STATUS=$?
    set -e # スクリプトを終了させる設定に戻す

    if [[ $CREATE_SERVICE_STATUS -ne 0 ]]; then
        echo "Error creating service ${SERVICE_NAME}. Skipping to next."
        continue
    fi
    echo "Successfully created service: ${SERVICE_NAME}"

    # ECS Exec 有効化コマンド
    echo -e "\n--- Enabling ECS Exec for ${SERVICE_NAME} ---"
    ENABLE_EXEC_CMD="aws ecs update-service \
      --region \"$REGION\" \
      --no-cli-pager \
      --cluster \"$CLUSTER_NAME\" \
      --service \"$SERVICE_NAME\" \
      --enable-execute-command"
    echo "$ENABLE_EXEC_CMD" # ★ここがコマンド表示のために追加された行
    set +e
    aws ecs update-service \
      --region "$REGION" \
      --no-cli-pager \
      --cluster "$CLUSTER_NAME" \
      --service "$SERVICE_NAME" \
      --enable-execute-command
    ENABLE_EXEC_STATUS=$?
    set -e
    if [[ $ENABLE_EXEC_STATUS -ne 0 ]]; then
        echo "Error enabling ECS Exec for service ${SERVICE_NAME}. Skipping to next."
    fi
    echo "Successfully enabled ECS Exec for service: ${SERVICE_NAME}"

    # Auto Scaling 設定
    RESOURCE_ID_AUTOSCALING="service/$CLUSTER_NAME/$SERVICE_NAME"

    # Scalable Target の登録
    echo -e "\n--- Registering Scalable Target for ${SERVICE_NAME} ---"
    REGISTER_SCALABLE_TARGET_CMD="aws application-autoscaling register-scalable-target \
      --region \"$REGION\" \
      --no-cli-pager \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id \"$RESOURCE_ID_AUTOSCALING\" \
      --min-capacity \"$MIN_CAPACITY\" \
      --max-capacity \"$MAX_CAPACITY\""
    echo "$REGISTER_SCALABLE_TARGET_CMD" # ★ここがコマンド表示のために追加された行
    set +e
    aws application-autoscaling register-scalable-target \
      --region "$REGION" \
      --no-cli-pager \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "$RESOURCE_ID_AUTOSCALING" \
      --min-capacity "$MIN_CAPACITY" \
      --max-capacity "$MAX_CAPACITY"
    REGISTER_SCALABLE_TARGET_STATUS=$?
    set -e
    if [[ $REGISTER_SCALABLE_TARGET_STATUS -ne 0 ]]; then
        echo "Error registering scalable target for service ${SERVICE_NAME}. Skipping to next."
    fi
    echo "Successfully registered scalable target for service: ${SERVICE_NAME}"

    # スケーリングポリシーの設定
    SCALING_POLICY_CONFIG_JSON="{\"TargetValue\": ${TARGET_VALUE}, \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageCPUUtilization\"}, \"ScaleOutCooldown\": ${OUT_COOLDOWN}, \"ScaleInCooldown\": ${IN_COOLDOWN}}"

    echo -e "\n--- Putting Scaling Policy for ${SERVICE_NAME} ---"
    PUT_SCALING_POLICY_CMD="aws application-autoscaling put-scaling-policy \
      --region \"$REGION\" \
      --no-cli-pager \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id \"$RESOURCE_ID_AUTOSCALING\" \
      --policy-name \"${SERVICE_NAME}-cpu-scale-policy\" \
      --policy-type TargetTrackingScaling \
      --target-tracking-scaling-policy-configuration '${SCALING_POLICY_CONFIG_JSON}'" # $SCALING_POLICY_CONFIG_JSON を一重引用符で囲む
    echo "$PUT_SCALING_POLICY_CMD" # ★ここがコマンド表示のために追加された行
    set +e
    aws application-autoscaling put-scaling-policy \
      --region "$REGION" \
      --no-cli-pager \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "$RESOURCE_ID_AUTOSCALING" \
      --policy-name "${SERVICE_NAME}-cpu-scale-policy" \
      --policy-type TargetTrackingScaling \
      --target-tracking-scaling-policy-configuration "${SCALING_POLICY_CONFIG_JSON}"
    PUT_SCALING_POLICY_STATUS=$?
    set -e
    if [[ $PUT_SCALING_POLICY_STATUS -ne 0 ]]; then
        echo "Error putting scaling policy for service ${SERVICE_NAME}."
    fi
    echo "Successfully put scaling policy for service: ${SERVICE_NAME}"

    echo -e "\n" $(printf -- '-%.0s' {1..80}) "\n" # 区切り線
done

echo "Script execution completed."
