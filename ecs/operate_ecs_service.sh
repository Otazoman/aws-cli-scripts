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
        echo "エラー: ${resource_type} の識別子は空にできません。" >&2
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
                resource_id=$(aws ec2 describe-security-groups --region "$region" --group-ids "$identifier" --query 'SecurityGroups[0].GroupId' --output text --no-cli-pager 2>/dev/null || echo "ERROR")
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
            echo "エラー: 不明なリソースタイプ: ${resource_type}" >&2
            return 1
            ;;
    esac

    if [[ -z "$resource_id" || "$resource_id" == "None" || "$resource_id" == "ERROR" ]]; then
        echo "エラー: リージョン ${region} で識別子 '${identifier}' の ${resource_type} が見つかりませんでした。" >&2
        return 1
    fi
    echo "$resource_id"
}

# サービスの存在確認 (ステータスに関わらず、サービス定義自体が存在するか)
# 戻り値: 0 (存在する), 1 (存在しない)
check_service_definition_exists() {
    local region="$1"
    local cluster_name="$2"
    local service_name="$3"
    local service_arn=$(aws ecs describe-services --region "$region" --cluster "$cluster_name" --services "$service_name" --query 'services[0].serviceArn' --output text --no-cli-pager 2>/dev/null)
    if [[ -n "$service_arn" && "$service_arn" != "None" ]]; then
        return 0 # サービス定義が存在する
    else
        return 1 # サービス定義が存在しない
    fi
}

# サービスの現在の状態を取得する関数
# 戻り値: ACTIVE, DRAINING, INACTIVE など、または空文字列（サービスが見つからない場合）
get_service_status() {
    local region="$1"
    local cluster_name="$2"
    local service_name="$3"
    local status=$(aws ecs describe-services --region "$region" --cluster "$cluster_name" --services "$service_name" --query 'services[0].status' --output text --no-cli-pager 2>/dev/null)
    if [[ "$status" == "None" ]]; then
        echo "" # サービスが見つからない場合は空文字列を返す
    else
        echo "$status"
    fi
}

# サービスがACTIVEになるまで待機する関数
wait_for_service_active() {
    local region="$1"
    local cluster_name="$2"
    local service_name="$3"
    local max_attempts=30 # 以前の10回から増やしました
    local delay=10 # seconds

    echo "サービス ${service_name} が ACTIVE 状態になるのを待機中..."

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        current_status=$(get_service_status "$region" "$cluster_name" "$service_name")
        if [ "$current_status" == "ACTIVE" ]; then
            echo "サービス ${service_name} は ACTIVE 状態になりました。"
            return 0
        elif [ -z "$current_status" ]; then
            echo "サービス ${service_name} が見つかりません。これは、作成処理に進む場合に正常な状態です。"
            return 0 # サービスが存在しない場合も、create-serviceに進むために成功として返す
        else
            echo "サービス ${service_name} は現在 ${current_status} 状態です。${delay}秒後に再試行します (試行 ${attempt}/${max_attempts})..."
            sleep "$delay"
        fi
    done

    echo "エラー: サービス ${service_name} がタイムアウト (${max_attempts}回の試行) しても ACTIVE 状態になりませんでした。" >&2
    return 1
}

# 既存のDRAINING状態のサービスを強制削除する関数
force_delete_draining_service() {
    local region="$1"
    local cluster_name="$2"
    local service_name="$3"

    echo "警告: サービス ${service_name} が DRAINING 状態のため、強制的に削除を試みます。"

    # まずdesired-countを0に設定してタスクを停止させる
    echo "--- サービス ${service_name} のdesired-countを0に設定中 ---"
    set +e # コマンド失敗時にスクリプトを終了させない
    aws ecs update-service \
        --region "$region" \
        --no-cli-pager \
        --cluster "$cluster_name" \
        --service "$service_name" \
        --desired-count 0 2>/dev/null
    local update_status=$?
    set -e
    if [[ $update_status -ne 0 ]]; then
        echo "警告: サービス ${service_name} のdesired-countを0に設定中にエラーが発生しました。（続行します）"
    fi

    # タスクが停止するまで待機 (最大60秒)
    echo "サービス ${service_name} のタスクが停止するまで最大60秒待機中..."
    for i in {1..6}; do # 10秒ごとに6回チェック
        local current_running_tasks=$(aws ecs describe-services --region "$region" --cluster "$cluster_name" --services "$service_name" --query 'services[0].runningCount' --output text --no-cli-pager 2>/dev/null || echo "ERROR")
        if [[ "$current_running_tasks" == "0" || "$current_running_tasks" == "None" || "$current_running_tasks" == "ERROR" ]]; then
            echo "サービス ${service_name} のタスクは停止しました。"
            break
        fi
        sleep 10
    done

    echo "--- サービス ${service_name} を強制削除中 ---"
    set +e # コマンド失敗時にスクリプトを終了させない
    aws ecs delete-service \
        --region "$region" \
        --no-cli-pager \
        --cluster "$cluster_name" \
        --service "$service_name" --force 2>/dev/null
    local delete_status=$?
    set -e
    if [[ $delete_status -ne 0 ]]; then
        echo "エラー: サービス ${service_name} の強制削除中にエラーが発生しました。このサービスはスキップします。" >&2
        return 1
    fi
    echo "サービス ${service_name} を正常に強制削除しました。"
    return 0
}


# サービス作成/更新共通のロジック
# 引数1: リージョン
# 引数2: クラスター名
# 引数3: タスク定義名
# 引数4: サービス名
# 引数5: 起動タイプ
# 引数6: 希望するタスク数
# 引数7: サブネット入力 (セミコロン区切り)
# 引数8: セキュリティグループ入力 (セミコロン区切り)
# 引数9: パブリックIP割り当て
# 引数10: ターゲットグループ入力
# 引数11: コンテナ名
# 引数12: コンテナポート
# 引数13: ヘルスチェック猶予期間
# 引数14: 最小キャパシティ
# 引数15: 最大キャパシティ
# 引数16: ターゲット値 (CPU使用率など)
# 引数17: スケールアウトクールダウン (秒)
# 引数18: スケールインクールダウン (秒)
# 引数19: タグ文字列 (セミコロン区切り Key:Value)
# 引数20: デプロイコントローラータイプ (ECS or CODE_DEPLOY)
create_or_update_service() {
    local REGION="$1"
    local CLUSTER_NAME="$2"
    local TASK_DEFINITION_NAME="$3"
    local SERVICE_NAME="$4"
    local LAUNCH_TYPE="$5"
    local DESIRED_COUNT="$6"
    local SUBNETS_INPUT="$7"
    local SECURITY_GROUPS_INPUT="$8"
    local PUBLIC_IP="$9"
    local TARGET_GROUP_INPUT="${10}"
    local CONTAINER_NAME="${11}"
    local CONTAINER_PORT="${12}"
    local HEALTH_CHECK_PERIOD="${13}"
    local MIN_CAPACITY="${14}"
    local MAX_CAPACITY="${15}"
    local TARGET_VALUE="${16}"
    local OUT_COOLDOWN="${17}"
    local IN_COOLDOWN="${18}"
    local TAGS_STR="${19}"
    local DEPLOYMENT_CONTROLLER="${20}" # 新しい引数

    local SERVICE_DEFINITION_EXISTS=false
    if check_service_definition_exists "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME"; then
        SERVICE_DEFINITION_EXISTS=true
    fi

    if $SERVICE_DEFINITION_EXISTS; then
        echo "サービス ${SERVICE_NAME} の定義はリージョン ${REGION} に既に存在します。更新を試みます。"

        # サービスがACTIVEになるまで待機
        if ! wait_for_service_active "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME"; then
            echo "エラー: サービス ${SERVICE_NAME} が ACTIVE 状態になりませんでした。更新をスキップします。" >&2
            return 1
        fi

        # ECS サービス更新コマンド
        echo -e "\n--- ECS サービス ${SERVICE_NAME} を更新中 ---"
        local UPDATE_SERVICE_CMD="aws ecs update-service \
            --region \"$REGION\" \
            --no-cli-pager \
            --cluster \"$CLUSTER_NAME\" \
            --service \"$SERVICE_NAME\""
            
        if [[ -n "$TASK_DEFINITION_NAME" ]]; then
            UPDATE_SERVICE_CMD+=" --task-definition \"$TASK_DEFINITION_NAME\""
        fi
        if [[ -n "$DESIRED_COUNT" ]]; then
            UPDATE_SERVICE_CMD+=" --desired-count \"$DESIRED_COUNT\""
        fi
        if [[ -n "$HEALTH_CHECK_PERIOD" ]]; then
            UPDATE_SERVICE_CMD+=" --health-check-grace-period-seconds \"$HEALTH_CHECK_PERIOD\""
        fi
        # デプロイコントローラーはcreate-serviceでしか指定できないため、updateでは除外
        
        echo "$UPDATE_SERVICE_CMD"
        set +e # コマンド失敗時にスクリプトを終了させない
        eval "$UPDATE_SERVICE_CMD"
        local UPDATE_SERVICE_STATUS=$?
        set -e # スクリプトを終了させる設定に戻す

        if [[ $UPDATE_SERVICE_STATUS -ne 0 ]]; then
            echo "サービス ${SERVICE_NAME} の更新中にエラーが発生しました。このサービスはスキップします。"
            return 1 # エラーを呼び出し元に伝える
        fi
        echo "サービス ${SERVICE_NAME} を正常に更新しました。"
    else
        echo "サービス ${SERVICE_NAME} の定義はリージョン ${REGION} に存在しません。新規作成を試みます。"

        # 新規作成前に、同じ名前のサービスがDRAINING状態でないか確認し、あれば強制削除
        local current_service_status=$(get_service_status "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME")
        if [[ "$current_service_status" == "DRAINING" ]]; then
            echo "警告: サービス ${SERVICE_NAME} は現在 DRAINING 状態です。強制的に削除して再作成します。"
            if ! force_delete_draining_service "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME"; then
                echo "エラー: DRAINING状態のサービス ${SERVICE_NAME} の強制削除に失敗しました。新規作成をスキップします。" >&2
                return 1
            fi
            # 削除後、完全に消滅するまで少し待つ
            sleep 5
            # 再度存在しないことを確認 (念のため)
            if check_service_definition_exists "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME"; then
                echo "エラー: サービス ${SERVICE_NAME} が削除後もまだ存在します。新規作成をスキップします。" >&2
                return 1
            fi
        fi

        # サブネットIDの解決
        local SUBNET_IDS_ARRAY=()
        IFS=';' read -r -a ADDR <<< "$SUBNETS_INPUT"
        for i in "${ADDR[@]}"; do
            i=$(echo "$i" | xargs) # 前後の空白をトリム
            if [[ -z "$i" ]]; then continue; fi # 空の要素はスキップ
            local subnet_id=$(get_resource_id "subnet" "$i" "$REGION")
            if [[ $? -ne 0 ]]; then
                echo "サブネット解決エラーのため、サービス ${SERVICE_NAME} の作成をスキップします。"
                return 1
            fi
            SUBNET_IDS_ARRAY+=("$(printf '%q' "$subnet_id")") # シェルセーフに引用符付け
        done
        local SUBNET_IDS=$(IFS=','; echo "${SUBNET_IDS_ARRAY[*]}")

        # セキュリティグループIDの解決
        local SECURITY_GROUP_IDS_ARRAY=()
        IFS=';' read -r -a ADDR <<< "$SECURITY_GROUPS_INPUT"
        for i in "${ADDR[@]}"; do
            i=$(echo "$i" | xargs) # 前後の空白をトリム
            if [[ -z "$i" ]]; then continue; fi # 空の要素はスキップ
            local sg_id=$(get_resource_id "securitygroup" "$i" "$REGION")
            if [[ $? -ne 0 ]]; then
                echo "セキュリティグループ解決エラーのため、サービス ${SERVICE_NAME} の作成をスキップします。"
                return 1
            fi
            SECURITY_GROUP_IDS_ARRAY+=("$(printf '%q' "$sg_id")") # シェルセーフに引用符付け
        done
        local SECURITY_GROUP_IDS=$(IFS=','; echo "${SECURITY_GROUP_IDS_ARRAY[*]}")

        # awsvpcConfigurationの整形
        local NETWORK_CONF="awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SECURITY_GROUP_IDS}],assignPublicIp=${PUBLIC_IP}}"

        # ターゲットグループARNの解決
        local TARGET_GROUP_ARN=$(get_resource_id "targetgroup" "$TARGET_GROUP_INPUT" "$REGION")
        if [[ $? -ne 0 ]]; then
            echo "ターゲットグループ解決エラーのため、サービス ${SERVICE_NAME} の作成をスキップします。"
            return 1
        fi

        # ロードバランサーのJSON形式を修正 (プロパティ名を二重引用符で囲む)
        local LOADBALANCERS="[{\"targetGroupArn\": \"${TARGET_GROUP_ARN}\",\"containerName\":\"${CONTAINER_NAME}\",\"containerPort\":${CONTAINER_PORT}}]"

        # ヘルスチェック間隔のデフォルト値設定
        if [[ -z "$HEALTH_CHECK_PERIOD" ]]; then
            HEALTH_CHECK_PERIOD=60
        fi

        # タグの整形
        local TAGS_CLI_ARG=""
        if [[ -n "$TAGS_STR" ]]; then
            IFS=';' read -r -a TAG_PAIRS <<< "$TAGS_STR"
            for PAIR in "${TAG_PAIRS[@]}"; do
                PAIR=$(echo "$PAIR" | xargs) # 前後の空白をトリム
                if [[ "$PAIR" =~ ":" ]]; then
                    local KEY=$(echo "$PAIR" | cut -d':' -f1 | xargs)
                    local VALUE=$(echo "$PAIR" | cut -d':' -f2- | xargs)
                    TAGS_CLI_ARG+="key=${KEY},value=${VALUE} "
                else
                    echo "警告: 不正なタグ形式 '${PAIR}' です。'Key:Value' 形式を期待します。このタグはサービス ${SERVICE_NAME} ではスキップされます。" >&2
                fi
            done
            TAGS_CLI_ARG="--tags $(echo "$TAGS_CLI_ARG" | xargs)"
        fi

        # ECS サービス作成コマンド
        echo -e "\n--- ECS サービス ${SERVICE_NAME} を作成中 ---"
        local CREATE_SERVICE_CMD="aws ecs create-service \
            --region \"$REGION\" \
            --no-cli-pager \
            --cluster \"$CLUSTER_NAME\" \
            --service-name \"$SERVICE_NAME\" \
            --task-definition \"$TASK_DEFINITION_NAME\" \
            --desired-count \"$DESIRED_COUNT\" \
            --launch-type \"$LAUNCH_TYPE\" \
            --network-configuration \"$NETWORK_CONF\" \
            --load-balancers '${LOADBALANCERS}' \
            --health-check-grace-period-seconds \"$HEALTH_CHECK_PERIOD\""

        # デプロイコントローラーの指定
        if [[ -n "$DEPLOYMENT_CONTROLLER" ]]; then
            CREATE_SERVICE_CMD+=" --deployment-controller type=${DEPLOYMENT_CONTROLLER}"
        fi
            
        if [[ -n "$TAGS_CLI_ARG" ]]; then
            CREATE_SERVICE_CMD+=" $TAGS_CLI_ARG"
        fi
        echo "$CREATE_SERVICE_CMD"

        set +e # コマンド失敗時にスクリプトを終了させない
        eval "$CREATE_SERVICE_CMD"
        local CREATE_SERVICE_STATUS=$?
        set -e # スクリプトを終了させる設定に戻す

        if [[ $CREATE_SERVICE_STATUS -ne 0 ]]; then
            echo "サービス ${SERVICE_NAME} の作成中にエラーが発生しました。このサービスはスキップします。"
            return 1
        fi
        echo "サービス ${SERVICE_NAME} を正常に作成しました。"
    fi

    # ECS Exec 有効化コマンド（作成/更新に関わらず実行）
    echo -e "\n--- ECS Exec をサービス ${SERVICE_NAME} で有効化中 ---"
    local ENABLE_EXEC_CMD="aws ecs update-service \
        --region \"$REGION\" \
        --no-cli-pager \
        --cluster \"$CLUSTER_NAME\" \
        --service \"$SERVICE_NAME\" \
        --enable-execute-command"
    echo "$ENABLE_EXEC_CMD"
    set +e
    eval "$ENABLE_EXEC_CMD"
    local ENABLE_EXEC_STATUS=$?
    set -e
    if [[ $ENABLE_EXEC_STATUS -ne 0 ]]; then
        echo "サービス ${SERVICE_NAME} のECS Exec有効化中にエラーが発生しました。"
    fi
    echo "サービス ${SERVICE_NAME} でECS Exec を正常に有効化しました。"

    # Auto Scaling 設定（作成/更新に関わらず実行）
    local RESOURCE_ID_AUTOSCALING="service/$CLUSTER_NAME/$SERVICE_NAME"

    # Scalable Target の登録/更新
    echo -e "\n--- サービス ${SERVICE_NAME} のスケーラブルターゲットを登録/更新中 ---"
    local REGISTER_SCALABLE_TARGET_CMD="aws application-autoscaling register-scalable-target \
        --region \"$REGION\" \
        --no-cli-pager \
        --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount \
        --resource-id \"$RESOURCE_ID_AUTOSCALING\" \
        --min-capacity \"$MIN_CAPACITY\" \
        --max-capacity \"$MAX_CAPACITY\""
    echo "$REGISTER_SCALABLE_TARGET_CMD"
    set +e
    eval "$REGISTER_SCALABLE_TARGET_CMD"
    local REGISTER_SCALABLE_TARGET_STATUS=$?
    set -e
    if [[ $REGISTER_SCALABLE_TARGET_STATUS -ne 0 ]]; then
        echo "サービス ${SERVICE_NAME} のスケーラブルターゲット登録/更新中にエラーが発生しました。"
    fi
    echo "サービス ${SERVICE_NAME} のスケーラブルターゲットを正常に登録/更新しました。"

    # スケーリングポリシーの設定/更新
    local SCALING_POLICY_CONFIG_JSON="{\"TargetValue\": ${TARGET_VALUE}, \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageCPUUtilization\"}, \"ScaleOutCooldown\": ${OUT_COOLDOWN}, \"ScaleInCooldown\": ${IN_COOLDOWN}}"

    echo -e "\n--- サービス ${SERVICE_NAME} のスケーリングポリシーを設定/更新中 ---"
    local PUT_SCALING_POLICY_CMD="aws application-autoscaling put-scaling-policy \
        --region \"$REGION\" \
        --no-cli-pager \
        --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount \
        --resource-id \"$RESOURCE_ID_AUTOSCALING\" \
        --policy-name \"${SERVICE_NAME}-cpu-scale-policy\" \
        --policy-type TargetTrackingScaling \
        --target-tracking-scaling-policy-configuration '${SCALING_POLICY_CONFIG_JSON}'"
    echo "$PUT_SCALING_POLICY_CMD"
    set +e
    eval "$PUT_SCALING_POLICY_CMD"
    local PUT_SCALING_POLICY_STATUS=$?
    set -e
    if [[ $PUT_SCALING_POLICY_STATUS -ne 0 ]]; then
        echo "サービス ${SERVICE_NAME} のスケーリングポリシー設定/更新中にエラーが発生しました。"
    fi
    echo "サービス ${SERVICE_NAME} のスケーリングポリシーを正常に設定/更新しました。"
    return 0 # 成功
}


# CSVファイル名の確認
if [[ -z "$1" ]]; then
    echo "使用法: $0 <CSV_ファイルパス>"
    exit 1
fi

CSV_FILE="$1"

# CSVファイルのヘッダー行をスキップして各行を処理
tail -n +2 "$CSV_FILE" | while IFS=',' read -r \
    REGION \
    ACTION \
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
    DEPLOYMENT_CONTROLLER \
    _unused # 余分な列を吸収するためのダミー変数
do
    # 空行のスキップ (末尾に空行がある場合など)
    if [[ -z "$REGION" ]]; then
        continue
    fi

    echo "--- サービス: ${SERVICE_NAME} (リージョン: ${REGION}, アクション: ${ACTION}) を処理中 ---"

    # アクションに基づいて処理を分岐
    case "$ACTION" in
        "add")
            # 存在しない場合は新規作成、存在するなら更新 (upsert ロジック)
            # デプロイコントローラーは新規作成時のみ有効
            create_or_update_service "$REGION" "$CLUSTER_NAME" "$TASK_DEFINITION_NAME" "$SERVICE_NAME" \
                "$LAUNCH_TYPE" "$DESIRED_COUNT" "$SUBNETS_INPUT" "$SECURITY_GROUPS_INPUT" \
                "$PUBLIC_IP" "$TARGET_GROUP_INPUT" "$CONTAINER_NAME" "$CONTAINER_PORT" \
                "$HEALTH_CHECK_PERIOD" "$MIN_CAPACITY" "$MAX_CAPACITY" "$TARGET_VALUE" \
                "$OUT_COOLDOWN" "$IN_COOLDOWN" "$TAGS_STR" "$DEPLOYMENT_CONTROLLER" || continue # エラーがあれば次のサービスへスキップ
            ;;

        "remove")
            # サービスの存在を確認
            SERVICE_DEFINITION_EXISTS=false
            if check_service_definition_exists "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME"; then
                SERVICE_DEFINITION_EXISTS=true
            fi

            if ! $SERVICE_DEFINITION_EXISTS; then
                echo "エラー: サービス ${SERVICE_NAME} は存在しないため、削除処理をスキップします。" >&2
                continue
            fi

            echo -e "\n--- サービス ${SERVICE_NAME} の Auto Scaling ポリシーを削除中 ---"
            set +e
            aws application-autoscaling delete-scaling-policy \
                --region "$REGION" \
                --no-cli-pager \
                --service-namespace ecs \
                --scalable-dimension ecs:service:DesiredCount \
                --resource-id "service/$CLUSTER_NAME/$SERVICE_NAME" \
                --policy-name "${SERVICE_NAME}-cpu-scale-policy" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                echo "警告: サービス ${SERVICE_NAME} のスケーリングポリシー削除中にエラーが発生しました。（スキップします）"
            else
                echo "サービス ${SERVICE_NAME} のスケーリングポリシーを正常に削除しました。"
            fi
            set -e

            echo -e "\n--- サービス ${SERVICE_NAME} のスケーラブルターゲットの登録を解除中 ---"
            set +e
            aws application-autoscaling deregister-scalable-target \
                --region "$REGION" \
                --no-cli-pager \
                --service-namespace ecs \
                --scalable-dimension ecs:service:DesiredCount \
                --resource-id "service/$CLUSTER_NAME/$SERVICE_NAME" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                echo "警告: サービス ${SERVICE_NAME} のスケーラブルターゲットの登録解除中にエラーが発生しました。（スキップします）"
            else
                echo "サービス ${SERVICE_NAME} のスケーラブルターゲットの登録を正常に解除しました。"
            fi
            set -e

            # desired-countを0に設定してタスクを停止させる処理は force_delete_draining_service 関数に集約済み
            # 削除処理を force_delete_draining_service 関数に委譲
            if ! force_delete_draining_service "$REGION" "$CLUSTER_NAME" "$SERVICE_NAME"; then
                echo "サービス ${SERVICE_NAME} の削除中にエラーが発生しました。次のサービスへスキップします。"
                continue
            fi
            ;;
            
        *)
            echo "エラー: 不明なアクション: ${ACTION} です。'add' または 'remove' のいずれかを指定してください。サービス ${SERVICE_NAME} をスキップします。" >&2
            continue
            ;;
    esac

    echo -e "\n" $(printf -- '-%.0s' {1..80}) "\n" # 区切り線
done

echo "スクリプトの実行が完了しました。"