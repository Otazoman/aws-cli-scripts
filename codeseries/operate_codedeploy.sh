#!/bin/bash

# ヘルプメッセージの表示
function usage() {
  echo "使い方: $0 <csv_file>"
  echo "  <csv_file>: CSVファイルへのパス"
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
tail -n +2 "$CSV_FILE" | awk -F, '{ gsub(/\r/, ""); print }' | while IFS=, read -r ACTION APPLICATION_NAME AWS_REGION DEPLOYMENT_GROUP_NAME ROLE_NAME SERVICE_NAME CLUSTER_NAME TARGET_GROUP_NAME_BLUE TARGET_GROUP_NAME_GREEN LB_NAME PROD_LISTENER_PORT PROD_LISTENER_PROTOCOL TEST_LISTENER_PORT TEST_LISTENER_PROTOCOL; do

  echo "----------------------------------------------------"
  echo "アプリケーションの処理中: ${APPLICATION_NAME}"
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
      aws deploy create-application \
        --region "${AWS_REGION}" \
        --application-name "${APPLICATION_NAME}" \
        --compute-platform ECS

      if [ $? -ne 0 ]; then
        echo "エラー: アプリケーション '${APPLICATION_NAME}' の作成に失敗しました。このアプリケーションの処理をスキップします。"
        continue
      else
        echo "CodeDeployアプリケーション '${APPLICATION_NAME}' を正常に作成しました。"
      fi
    else
      echo "CodeDeployアプリケーション '${APPLICATION_NAME}' は既に存在します。"
    fi

    # CodeDeployサービスロールのARNを取得 (変更なし)
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

    # ターゲットグループARNの取得 (Blue) (変更なし)
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

    # ターゲットグループARNの取得 (Green) (変更なし)
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

    # ロードバランサーARNの取得 (変更なし)
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

    # プロダクションリスナーARNの取得 (変更なし)
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

    # テストリスナーARNの取得 (変更なし)
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

    # CodeDeployデプロイグループの作成 (変更なし)
    # 既存のデプロイグループが存在するか確認
    echo "CodeDeployデプロイグループ '${DEPLOYMENT_GROUP_NAME}' の存在を確認中..."
    EXISTING_DG_ARN=$(aws deploy get-deployment-group --application-name "${APPLICATION_NAME}" --deployment-group-name "${DEPLOYMENT_GROUP_NAME}" --query 'deploymentGroupInfo.deploymentGroupArn' --output text 2>/dev/null)

    if [ -z "$EXISTING_DG_ARN" ]; then
      echo "CodeDeployデプロイグループ '${DEPLOYMENT_GROUP_NAME}' が見つかりませんでした。作成します..."
      aws deploy create-deployment-group \
        --region "${AWS_REGION}" \
        --application-name "${APPLICATION_NAME}" \
        --deployment-group-name "${DEPLOYMENT_GROUP_NAME}" \
        --service-role-arn "${CODEDEPLOY_SERVICE_ROLE_ARN}" \
        --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
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
        --alarm-configuration '{"enabled":false,"alarms":[]}'

      if [ $? -ne 0 ]; then
        echo "エラー: アプリケーション '${APPLICATION_NAME}' のデプロイグループ '${DEPLOYMENT_GROUP_NAME}' の作成に失敗しました。"
      else
        echo "デプロイグループ '${DEPLOYMENT_GROUP_NAME}' を正常に作成しました。"
      fi
    else
      echo "デプロイグループ '${DEPLOYMENT_GROUP_NAME}' は既に存在します。スキップします。"
    fi
  fi
  echo "" # 空行を追加して見やすくする

done

echo "スクリプトが完了しました。"