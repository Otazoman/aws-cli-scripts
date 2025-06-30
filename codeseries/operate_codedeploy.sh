#!/bin/bash

# ヘルプメッセージの表示
function usage() {
  echo "使い方: $0 <csv_file>"
  echo "  <csv_file>: CSVファイルへのパス"
  echo ""
  echo "CSVファイルの書式:"
  echo "  - COMPUTE_PLATFORM: ECS, Server, Lambdaのいずれかを指定"
  echo "  - TAGS: キー1:値1;キー2:値2;キー3:値3 (セミコロンで区切り)"
  echo "  - EC2_TAG_TYPE: KEY_ONLY, VALUE_ONLY, KEY_AND_VALUEのいずれか"
  exit 1
}

# 引数のチェック
if [ -z "$1" ]; then
  usage
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
  echo "エラー: CSVファイル '${CSV_FILE}' が見つかりません。"
  exit 1
fi

# CSVファイルを読み込み、各行を処理
# IFS (Internal Field Separator) を変更してカンマ区切りで読み込む
# -r オプションでバックスラッシュのエスケープを無効にする
# tail -n +2 でヘッダー行をスキップ
# コメント行(#で始まる行)をスキップ
tail -n +2 "$CSV_FILE" | grep -v "^#" | awk -F, '{ gsub(/\r/, ""); print }' | while IFS= read -r LINE; do

  # コメント行やデータがない行はスキップ
  if [ -z "$LINE" ] || [[ "$LINE" =~ ^[[:space:]]*# ]]; then
    continue
  fi

  # 各フィールドをawkで明示的に抽出
  ACTION=$(echo "$LINE" | awk -F, '{print $1}')
  COMPUTE_PLATFORM=$(echo "$LINE" | awk -F, '{print $2}')
  APPLICATION_NAME=$(echo "$LINE" | awk -F, '{print $3}')
  AWS_REGION=$(echo "$LINE" | awk -F, '{print $4}')
  DEPLOYMENT_GROUP_NAME=$(echo "$LINE" | awk -F, '{print $5}')
  ROLE_NAME=$(echo "$LINE" | awk -F, '{print $6}')
  TAGS=$(echo "$LINE" | awk -F, '{print $7}')
  SERVICE_NAME=$(echo "$LINE" | awk -F, '{print $8}')
  CLUSTER_NAME=$(echo "$LINE" | awk -F, '{print $9}')
  TARGET_GROUP_NAME_BLUE=$(echo "$LINE" | awk -F, '{print $10}')
  TARGET_GROUP_NAME_GREEN=$(echo "$LINE" | awk -F, '{print $11}')
  LB_NAME=$(echo "$LINE" | awk -F, '{print $12}')
  PROD_LISTENER_PORT=$(echo "$LINE" | awk -F, '{print $13}')
  PROD_LISTENER_PROTOCOL=$(echo "$LINE" | awk -F, '{print $14}')
  TEST_LISTENER_PORT=$(echo "$LINE" | awk -F, '{print $15}')
  TEST_LISTENER_PROTOCOL=$(echo "$LINE" | awk -F, '{print $16}')
  AUTO_SCALING_GROUP=$(echo "$LINE" | awk -F, '{print $17}')
  DEPLOYMENT_CONFIG=$(echo "$LINE" | awk -F, '{print $18}')
  EC2_TAG_KEY=$(echo "$LINE" | awk -F, '{print $19}')
  EC2_TAG_VALUE=$(echo "$LINE" | awk -F, '{print $20}')
  EC2_TAG_TYPE=$(echo "$LINE" | awk -F, '{print $21}')
  LAMBDA_ALIAS=$(echo "$LINE" | awk -F, '{print $22}')
  CURRENT_VERSION=$(echo "$LINE" | awk -F, '{print $23}')
  TARGET_VERSION=$(echo "$LINE" | awk -F, '{print $24}')


  echo "----------------------------------------------------"
  echo "アプリケーションの処理中: ${APPLICATION_NAME}"
  echo "コンピューティングプラットフォーム: ${COMPUTE_PLATFORM}"
  echo "リージョン: ${AWS_REGION}"
  echo "アクション: ${ACTION}"
  echo "----------------------------------------------------"

  if [ "$ACTION" == "remove" ]; then
    # デプロイグループの削除
    echo "CodeDeployデプロイグループ '${DEPLOYMENT_GROUP_NAME}' を削除中..."
    aws deploy delete-deployment-group \
      --application-name "${APPLICATION_NAME}" \
      --deployment-group-name "${DEPLOYMENT_GROUP_NAME}" \
      --region "${AWS_REGION}"

    if [ $? -ne 0 ]; then
      echo "エラー: デプロイグループ '${DEPLOYMENT_GROUP_NAME}' の削除に失敗しました。"
      # 削除に失敗した場合は、アプリケーションのチェックはスキップ
    else
      echo "デプロイグループ '${DEPLOYMENT_GROUP_NAME}' を正常に削除しました。"

      # デプロイグループ削除後、アプリケーションに他のデプロイグループが残っていないか確認し、あれば削除
      echo "アプリケーション '${APPLICATION_NAME}' (リージョン: ${AWS_REGION}) に関連するデプロイグループを確認中..."

      # list-deployment-groups がエラーになった場合、DG_COUNT は0とする
      # アプリケーションが存在しない場合も、デプロイグループは0であるとみなす
      DG_COUNT=$(aws deploy list-deployment-groups \
        --application-name "${APPLICATION_NAME}" \
        --region "${AWS_REGION}" \
        --query 'deploymentGroups | length(@)' \
        --output text \
        2>/dev/null || echo "0") # <-- ここを変更: コマンドが失敗したら "0" を出力

      if [ -z "$DG_COUNT" ]; then # DG_COUNTが空の場合の安全策（念のため）
        DG_COUNT=0
      fi

      if [ "$DG_COUNT" -eq 0 ]; then
        echo "アプリケーション '${APPLICATION_NAME}' に関連するデプロイグループがありません。アプリケーションを削除します..."
        aws deploy delete-application \
          --application-name "${APPLICATION_NAME}" \
          --region "${AWS_REGION}"

        if [ $? -ne 0 ]; then
          echo "エラー: アプリケーション '${APPLICATION_NAME}' の削除に失敗しました。"
        else
          echo "アプリケーション '${APPLICATION_NAME}' を正常に削除しました。"
        fi
      else
        echo "アプリケーション '${APPLICATION_NAME}' には ${DG_COUNT} 個のデプロイグループが残っています。アプリケーションは削除されません。"
      fi
    fi
  else
    # CodeDeployアプリケーションの存在チェック (変更なし)
    echo "CodeDeployアプリケーション '${APPLICATION_NAME}' の存在を確認中..."
    EXISTING_APP_ARN=$(aws deploy get-application --application-name "${APPLICATION_NAME}" --query 'application.applicationArn' --output text 2>/dev/null)

    if [ -z "$EXISTING_APP_ARN" ]; then
      # アプリケーションが存在しない場合のみ作成
      echo "CodeDeployアプリケーション '${APPLICATION_NAME}' が見つかりませんでした。作成します..."
      
      # タグの処理
      TAG_ARRAY_CLI=() # CLIに渡すための配列を初期化
      if [ ! -z "$TAGS" ]; then
        echo "アプリケーションにタグを追加します: ${TAGS}"
        IFS=';' read -ra TAG_ARRAY_RAW <<< "$TAGS"
        for TAG_ITEM in "${TAG_ARRAY_RAW[@]}"; do
          KEY=$(echo "$TAG_ITEM" | cut -d':' -f1)
          VALUE=$(echo "$TAG_ITEM" | cut -d':' -f2)
          # "Key=キー,Value=値" の形式で配列に要素を追加
          TAG_ARRAY_CLI+=("Key=${KEY},Value=${VALUE}")
        done
      fi
      
      # アプリケーション作成コマンドを直接実行
      aws deploy create-application \
        --region "${AWS_REGION}" \
        --application-name "${APPLICATION_NAME}" \
        --compute-platform "${COMPUTE_PLATFORM}" \
        ${TAG_ARRAY_CLI[@]:+--tags "${TAG_ARRAY_CLI[@]}"}

      if [ $? -ne 0 ]; then
        echo "エラー: アプリケーション '${APPLICATION_NAME}' の作成に失敗しました。このアプリケーションの処理をスキップします。"
        continue
      else
        echo "CodeDeployアプリケーション '${APPLICATION_NAME}' を正常に作成しました。"
      fi
    else
      echo "CodeDeployアプリケーション '${APPLICATION_NAME}' は既に存在します。"
    fi

    # CodeDeployサービスロールのARNを取得
    echo "CodeDeployサービスロール '${ROLE_NAME}' のARNを取得中..."
    CODEDEPLOY_SERVICE_ROLE_ARN=$( \
      aws iam get-role \
        --role-name "${ROLE_NAME}" \
        --query 'Role.Arn' \
        --output text \
    )

    if [ -z "$CODEDEPLOY_SERVICE_ROLE_ARN" ]; then
      echo "エラー: CodeDeployサービスロール '${ROLE_NAME}' が見つからないか、ARNを取得できませんでした。デプロイグループの作成をスキップします。"
      continue
    fi
    echo "CodeDeployサービスロールARN: ${CODEDEPLOY_SERVICE_ROLE_ARN}"

    # CodeDeployデプロイグループの作成
    # 既存のデプロイグループが存在するか確認
    echo "CodeDeployデプロイグループ '${DEPLOYMENT_GROUP_NAME}' の存在を確認中..."
    EXISTING_DG_ARN=$(aws deploy get-deployment-group --application-name "${APPLICATION_NAME}" --deployment-group-name "${DEPLOYMENT_GROUP_NAME}" --query 'deploymentGroupInfo.deploymentGroupArn' --output text 2>/dev/null)

    if [ -z "$EXISTING_DG_ARN" ]; then
      echo "CodeDeployデプロイグループ '${DEPLOYMENT_GROUP_NAME}' が見つかりませんでした。作成します..."
      
      # タグの処理（デプロイグループ用）
      DG_TAG_ARRAY_CLI=() # CLIに渡すための配列を初期化
      if [ ! -z "$TAGS" ]; then
        echo "デプロイグループにタグを追加します: ${TAGS}"
        IFS=';' read -ra TAG_ARRAY_RAW <<< "$TAGS"
        for TAG_ITEM in "${TAG_ARRAY_RAW[@]}"; do
          KEY=$(echo "$TAG_ITEM" | cut -d':' -f1)
          VALUE=$(echo "$TAG_ITEM" | cut -d':' -f2)
          # "Key=キー,Value=値" の形式で配列に要素を追加
          DG_TAG_ARRAY_CLI+=("Key=${KEY},Value=${VALUE}")
        done
      fi
      
      # コンピューティングプラットフォームに応じた処理
      case "$COMPUTE_PLATFORM" in
        "ECS")
          # ECSの場合の処理
          # ターゲットグループARNの取得 (Blue)
          echo "ターゲットグループ '${TARGET_GROUP_NAME_BLUE}' (Blue) のARNを取得中..."
          TG_ARN_BLUE=$( \
            aws elbv2 describe-target-groups \
              --names "${TARGET_GROUP_NAME_BLUE}" \
              --query 'TargetGroups[0].TargetGroupArn' \
              --output text \
          )

          if [ -z "$TG_ARN_BLUE" ]; then
            echo "エラー: ターゲットグループ '${TARGET_GROUP_NAME_BLUE}' が見つからないか、ARNを取得できませんでした。デプロイグループの作成をスキップします。"
            continue
          fi
          echo "ターゲットグループARN (Blue): ${TG_ARN_BLUE}"

          # ターゲットグループARNの取得 (Green)
          echo "ターゲットグループ '${TARGET_GROUP_NAME_GREEN}' (Green) のARNを取得中..."
          TG_ARN_GREEN=$( \
            aws elbv2 describe-target-groups \
              --names "${TARGET_GROUP_NAME_GREEN}" \
              --query 'TargetGroups[0].TargetGroupArn' \
              --output text \
          )

          if [ -z "$TG_ARN_GREEN" ]; then
            echo "エラー: ターゲットグループ '${TARGET_GROUP_NAME_GREEN}' が見つからないか、ARNを取得できませんでした。デプロイグループの作成をスキップします。"
            continue
          fi
          echo "ターゲットグループARN (Green): ${TG_ARN_GREEN}"

          # ロードバランサーARNの取得
          echo "ロードバランサー名 '${LB_NAME}' のARNを取得中 (リージョン: ${AWS_REGION})..."
          LB_ARN=$( \
            aws elbv2 describe-load-balancers \
              --names "${LB_NAME}" \
              --query 'LoadBalancers[0].LoadBalancerArn' \
              --output text \
              --region "${AWS_REGION}" \
          )

          if [ -z "$LB_ARN" ]; then
            echo "エラー: ロードバランサー '${LB_NAME}' が見つからないか、ARNを取得できませんでした。デプロイグループの作成をスキップします。"
            continue
          fi
          echo "ロードバランサーARN: ${LB_ARN}"

          # プロダクションリスナーARNの取得
          echo "プロダクションリスナーARNを取得中 (LB: ${LB_NAME}, ポート: ${PROD_LISTENER_PORT}, プロトコル: ${PROD_LISTENER_PROTOCOL})..."
          LISTENER_ARN=$( \
            aws elbv2 describe-listeners \
              --load-balancer-arn "${LB_ARN}" \
              --query "Listeners[?Port==\`${PROD_LISTENER_PORT}\` && Protocol=='${PROD_LISTENER_PROTOCOL}'].ListenerArn" \
              --output text \
              --region "${AWS_REGION}" \
          )

          if [ -z "$LISTENER_ARN" ]; then
            echo "エラー: ロードバランサー '${LB_NAME}' のプロダクションリスナー (ポート: ${PROD_LISTENER_PORT}, プロトコル: ${PROD_LISTENER_PROTOCOL}) が見つかりませんでした。デプロイグループの作成をスキップします。"
            continue
          fi
          echo "プロダクションリスナーARN: ${LISTENER_ARN}"

          # テストリスナーARNの取得
          echo "テストリスナーARNを取得中 (LB: ${LB_NAME}, ポート: ${TEST_LISTENER_PORT}, プロトコル: ${TEST_LISTENER_PROTOCOL})..."
          TEST_LISTENER_ARN=$( \
            aws elbv2 describe-listeners \
              --load-balancer-arn "${LB_ARN}" \
              --query "Listeners[?Port==\`${TEST_LISTENER_PORT}\` && Protocol=='${TEST_LISTENER_PROTOCOL}'].ListenerArn" \
              --output text \
              --region "${AWS_REGION}" \
          )

          if [ -z "$TEST_LISTENER_ARN" ]; then
            echo "エラー: ロードバランサー '${LB_NAME}' のテストリスナー (ポート: ${TEST_LISTENER_PORT}, プロトコル: ${TEST_LISTENER_PROTOCOL}) が見つかりませんでした。デプロイグループの作成をスキップします。"
            continue
          fi
          echo "テストリスナーARN: ${TEST_LISTENER_ARN}"

          # ECSデプロイグループの作成
          aws deploy create-deployment-group \
            --region "${AWS_REGION}" \
            --application-name "${APPLICATION_NAME}" \
            --deployment-group-name "${DEPLOYMENT_GROUP_NAME}" \
            --service-role-arn "${CODEDEPLOY_SERVICE_ROLE_ARN}" \
            --deployment-config-name "${DEPLOYMENT_CONFIG}" \
            --ecs-services "serviceName=${SERVICE_NAME},clusterName=${CLUSTER_NAME}" \
            --load-balancer-info "{
              \"targetGroupPairInfoList\":[
                {
                  \"targetGroups\":[
                    {\"name\":\"${TARGET_GROUP_NAME_BLUE}\"},
                    {\"name\":\"${TARGET_GROUP_NAME_GREEN}\"}
                  ],
                  \"prodTrafficRoute\":{
                    \"listenerArns\":[\"${LISTENER_ARN}\"]
                  },
                  \"testTrafficRoute\":{
                    \"listenerArns\":[\"${TEST_LISTENER_ARN}\"]
                  }
                }
              ]
            }" \
            --blue-green-deployment-configuration '{
              "terminateBlueInstancesOnDeploymentSuccess":{
                "action":"TERMINATE",
                "terminationWaitTimeInMinutes":5
              },
              "deploymentReadyOption":{
                "actionOnTimeout":"CONTINUE_DEPLOYMENT",
                "waitTimeInMinutes":0
              }
            }' \
            --auto-rollback-configuration '{"enabled":true,"events":["DEPLOYMENT_FAILURE"]}' \
            --deployment-style '{"deploymentType":"BLUE_GREEN","deploymentOption":"WITH_TRAFFIC_CONTROL"}' \
            --alarm-configuration '{"enabled":false,"alarms":[]}' \
            ${DG_TAG_ARRAY_CLI[@]:+--tags "${DG_TAG_ARRAY_CLI[@]}"}
          ;;
          
      "Server")
        # EC2(Server)の場合の処理
        # デプロイメント設定がない場合はデフォルト値を使用
        if [ -z "$DEPLOYMENT_CONFIG" ]; then
          DEPLOYMENT_CONFIG="CodeDeployDefault.OneAtATime"
        fi
        # コマンドを組み立てるための配列を初期化
        # まずは必須の引数をすべて追加
        CMD_ARGS=(
            "aws" "deploy" "create-deployment-group"
            "--region" "${AWS_REGION}"
            "--application-name" "${APPLICATION_NAME}"
            "--deployment-group-name" "${DEPLOYMENT_GROUP_NAME}"
            "--service-role-arn" "${CODEDEPLOY_SERVICE_ROLE_ARN}"
            "--deployment-config-name" "${DEPLOYMENT_CONFIG}"
            "--auto-rollback-configuration" '{"enabled":true,"events":["DEPLOYMENT_FAILURE"]}'
            "--alarm-configuration" '{"enabled":false,"alarms":[]}'
        )

        # Auto Scaling Groupが指定されている場合、配列に引数を追加
        if [ ! -z "$AUTO_SCALING_GROUP" ]; then
          echo "Auto Scaling Group '${AUTO_SCALING_GROUP}' を使用します"
          CMD_ARGS+=("--auto-scaling-groups" "${AUTO_SCALING_GROUP}")
        fi

        # EC2タグフィルターが指定されている場合、配列に引数を追加
        if [ ! -z "$EC2_TAG_KEY" ] && [ ! -z "$EC2_TAG_TYPE" ]; then
          echo "EC2タグフィルターを使用します: キー='${EC2_TAG_KEY}', 値='${EC2_TAG_VALUE}', タイプ='${EC2_TAG_TYPE}'"
          # 複数のタグフィルターを将来的にサポートする場合は、ここをループ処理にする
          CMD_ARGS+=("--ec2-tag-filters" "Key=${EC2_TAG_KEY},Value=${EC2_TAG_VALUE},Type=${EC2_TAG_TYPE}")
        fi

        # デプロイグループ用のタグが指定されている場合、配列に引数を追加
        # (この部分は既に配列 DG_TAG_ARRAY_CLI を使っているので、それを活用する)
        if [ ${#DG_TAG_ARRAY_CLI[@]} -gt 0 ]; then
          CMD_ARGS+=("--tags" "${DG_TAG_ARRAY_CLI[@]}")
        fi

        # 組み立てたコマンドを実行
        # "${CMD_ARGS[@]}" とすることで、各要素が正しくクォートされて安全に渡される
        "${CMD_ARGS[@]}"
        ;;
          
        "Lambda")
          # Lambda用のデプロイグループ作成
          if [ -z "$LAMBDA_ALIAS" ] || [ -z "$CURRENT_VERSION" ] || [ -z "$TARGET_VERSION" ]; then
            echo "エラー: Lambdaデプロイグループには LAMBDA_ALIAS, CURRENT_VERSION, TARGET_VERSION が必要です。デプロイグループの作成をスキップします。"
            continue
          fi
          
          echo "Lambda関数 '${APPLICATION_NAME}' のデプロイグループを作成します"
          echo "エイリアス: ${LAMBDA_ALIAS}, 現在バージョン: ${CURRENT_VERSION}, ターゲットバージョン: ${TARGET_VERSION}"

          aws deploy create-deployment-group \
            --region "${AWS_REGION}" \
            --application-name "${APPLICATION_NAME}" \
            --deployment-group-name "${DEPLOYMENT_GROUP_NAME}" \
            --service-role-arn "${CODEDEPLOY_SERVICE_ROLE_ARN}" \
            --deployment-style '{"deploymentType":"BLUE_GREEN","deploymentOption":"WITH_TRAFFIC_CONTROL"}' \
            --auto-rollback-configuration '{"enabled":true,"events":["DEPLOYMENT_FAILURE"]}' \
            --alarm-configuration '{"enabled":false,"alarms":[]}' \
            --deployment-config-name "${DEPLOYMENT_CONFIG}" \
            ${DG_TAG_ARRAY_CLI[@]:+--tags "${DG_TAG_ARRAY_CLI[@]}"}
          ;;
          
        *)
          echo "エラー: サポートされていないコンピューティングプラットフォーム '${COMPUTE_PLATFORM}' です。デプロイグループの作成をスキップします。"
          continue
          ;;
      esac

      if [ $? -ne 0 ]; then
        echo "エラー: アプリケーション '${APPLICATION_NAME}' のデプロイグループ '${DEPLOYMENT_GROUP_NAME}' の作成に失敗しました。"
      else
        echo "デプロイグループ '${DEPLOYMENT_GROUP_NAME}' を正常に作成しました。"
      fi
    else
      echo "デプロイグループ '${DEPLOYMENT_GROUP_NAME}' は既に存在します。スキップします。"
    fi
  fi
  # タグ情報を詳細表示
  if [ ! -z "$TAGS" ]; then
    echo "アプリケーションのタグ: ${TAGS}"
    echo "  タグ形式: キー:値 (複数タグはセミコロン区切り)"
    
    # タグの詳細情報を表示
    IFS=';' read -ra TAG_ARRAY <<< "$TAGS"
    echo "  設定されたタグ数: ${#TAG_ARRAY[@]}"
    for i in "${!TAG_ARRAY[@]}"; do
      TAG=${TAG_ARRAY[$i]}
      KEY=$(echo $TAG | cut -d':' -f1)
      VALUE=$(echo $TAG | cut -d':' -f2)
      echo "  - タグ $((i+1)): キー='${KEY}', 値='${VALUE}'"
    done
  else
    echo "タグは設定されていません"
  fi
  
  echo "" # 空行を追加して見やすくする

done

echo "スクリプトが完了しました。"
