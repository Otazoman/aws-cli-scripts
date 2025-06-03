#!/bin/bash

# CSVファイル名を引数から取得
if [ -z "$1" ]; then
    echo "使用法: $0 <CSVファイルのパス>"
    echo "例: $0 codebuild_projects.csv"
    exit 1
fi

CSV_FILE="$1" # 引数で渡されたファイル名を設定

# CSVファイルが存在するかチェック
if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: CSVファイル '$CSV_FILE' が見つかりません。"
    exit 1
fi

IAM_POLICY_NAME_PREFIX="CodeBuildServicePolicy" # IAMポリシー名のプレフィックス
DEFAULT_AWS_REGION="ap-northeast-1" # デフォルトリージョン (CSVで指定がない場合)

# 注: IAMロールは事前に設定されたものを使用するため、ポリシー定義は不要です

echo "CSVファイル: $CSV_FILE を使用してCodeBuildプロジェクト管理スクリプトを開始します"

# CSVファイルを読み込み、各行を処理
# IFS (Internal Field Separator) を変更してカンマ区切りで読み込む
# tail -n +2 でヘッダー行をスキップ
# ACTION列が追加されたため、read -r の変数を変更
cat "$CSV_FILE" | while IFS=, read -r ACTION PROJECT_NAME SOURCE_TYPE SOURCE_LOCATION IMAGE COMPUTE_TYPE ENVIRONMENT_TYPE SERVICE_ROLE_NAME BUILDSPEC ARTIFACTS_TYPE ARTIFACTS_LOCATION AWS_REGION_FROM_CSV; do

    # ヘッダー行をスキップ（空行やコメント行もスキップ）
    [[ "$ACTION" =~ ^ACTION$ ]] && continue
    [[ -z "$ACTION" ]] && continue # 空行スキップ

    CURRENT_REGION="${AWS_REGION_FROM_CSV:-$DEFAULT_AWS_REGION}" # CSVからリージョンを取得、なければデフォルト
    # IAMロールは事前に設定済みのものを使用する

    echo "--- プロジェクト: $PROJECT_NAME の $ACTION 処理を実行中（リージョン: $CURRENT_REGION）---"

    case "$ACTION" in
        add)
            # --- 既存IAMロールからARNを取得 ---
            echo "IAMロールのARNを取得しています: $SERVICE_ROLE_NAME..."
            SERVICE_ROLE_ARN=$(aws iam get-role --role-name "$SERVICE_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)

            if [ -z "$SERVICE_ROLE_ARN" ]; then
                echo "エラー: IAMロール '$SERVICE_ROLE_NAME' が見つかりません。このスクリプトを実行する前にロールが存在することを確認してください。プロジェクトをスキップします。"
                continue
            else
                echo "IAMロール '$SERVICE_ROLE_NAME' が見つかりました。ARN: $SERVICE_ROLE_ARN"
            fi

            # --- S3バケットの存在確認と作成 ---
            if [[ "$ARTIFACTS_TYPE" == "S3" && -n "$ARTIFACTS_LOCATION" ]]; then
                echo "S3バケットを確認中: $ARTIFACTS_LOCATION（リージョン: $CURRENT_REGION）..."
                aws s3api head-bucket --bucket "$ARTIFACTS_LOCATION" --region "$CURRENT_REGION" &>/dev/null

                if [ $? -ne 0 ]; then
                    echo "S3バケット '$ARTIFACTS_LOCATION' がリージョン '$CURRENT_REGION' に見つかりません。作成します..."
                    if [[ "$CURRENT_REGION" != "us-east-1" ]]; then
                        aws s3api create-bucket \
                            --bucket "$ARTIFACTS_LOCATION" \
                            --region "$CURRENT_REGION" \
                            --create-bucket-configuration LocationConstraint="$CURRENT_REGION" \
                            --output text 2>/dev/null
                    else
                        aws s3api create-bucket \
                            --bucket "$ARTIFACTS_LOCATION" \
                            --region "$CURRENT_REGION" \
                            --output text 2>/dev/null
                    fi

                    if [ $? -ne 0 ]; then
                        echo "エラー: S3バケット '$ARTIFACTS_LOCATION' をリージョン '$CURRENT_REGION' に作成できませんでした。プロジェクトをスキップします。"
                        continue
                    fi
                    echo "S3バケット '$ARTIFACTS_LOCATION' が正常に作成されました。"
                else
                    echo "S3バケット '$ARTIFACTS_LOCATION' は既に存在します。"
                fi
            fi

            # --- CodeBuildプロジェクトの作成 ---
            echo "CodeBuildプロジェクトを作成中: $PROJECT_NAME..."

            # JSONパラメータの構築
            SOURCE_JSON=$(cat <<EOF
{
    "type": "$SOURCE_TYPE",
    "location": "$SOURCE_LOCATION",
    "buildspec": "$BUILDSPEC"
}
EOF
)

            ARTIFACTS_JSON=$(cat <<EOF
{
    "type": "NO_ARTIFACTS"
}
EOF
)
            if [[ "$ARTIFACTS_TYPE" == "S3" && -n "$ARTIFACTS_LOCATION" ]]; then
                ARTIFACTS_JSON=$(cat <<EOF
{
    "type": "S3",
    "location": "$ARTIFACTS_LOCATION",
    "packaging": "ZIP",
    "name": "$PROJECT_NAME"
}
EOF
)
            fi

            ENVIRONMENT_JSON=$(cat <<EOF
{
    "type": "$ENVIRONMENT_TYPE",
    "image": "$IMAGE",
    "computeType": "$COMPUTE_TYPE",
    "environmentVariables": []
}
EOF
)

            aws codebuild create-project \
                --name "$PROJECT_NAME" \
                --source "$SOURCE_JSON" \
                --artifacts "$ARTIFACTS_JSON" \
                --environment "$ENVIRONMENT_JSON" \
                --service-role "$SERVICE_ROLE_ARN" \
                --description "スクリプトにより作成された $PROJECT_NAME のCodeBuildプロジェクト" \
                --region "$CURRENT_REGION" \
                --no-cli-pager 2>/dev/null

            if [ $? -eq 0 ]; then
                echo "プロジェクト '$PROJECT_NAME' が正常に作成されました！"
            else
                echo "エラー: プロジェクト '$PROJECT_NAME' の作成に失敗しました。既に存在するか、他の問題がある可能性があります。"
            fi
            ;;

        remove)
            # --- CodeBuildプロジェクトの削除 ---
            echo "CodeBuildプロジェクトの削除を試みています: $PROJECT_NAME（リージョン: $CURRENT_REGION）..."
            aws codebuild delete-project --name "$PROJECT_NAME" --region "$CURRENT_REGION" --no-cli-pager &>/dev/null

            if [ $? -eq 0 ]; then
                echo "CodeBuildプロジェクト '$PROJECT_NAME' が正常に削除されました！"
            else
                echo "CodeBuildプロジェクト '$PROJECT_NAME' が見つからないか、削除に失敗しました。スキップします。"
            fi

            # --- S3バケットの削除 ---
            if [[ "$ARTIFACTS_TYPE" == "S3" && -n "$ARTIFACTS_LOCATION" ]]; then
                echo "S3バケットの削除を試みています: $ARTIFACTS_LOCATION（リージョン: $CURRENT_REGION）..."
                aws s3api head-bucket --bucket "$ARTIFACTS_LOCATION" --region "$CURRENT_REGION" &>/dev/null

                if [ $? -eq 0 ]; then
                    echo "S3バケット '$ARTIFACTS_LOCATION' が存在します。まずコンテンツを削除します..."
                    aws s3 rm "s3://$ARTIFACTS_LOCATION" --recursive --region "$CURRENT_REGION" --no-cli-pager &>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "S3バケット '$ARTIFACTS_LOCATION' のコンテンツが削除されました。"
                    else
                        echo "警告: S3バケット '$ARTIFACTS_LOCATION' のコンテンツの削除に失敗しました。空であるか、権限の問題がある可能性があります。"
                    fi

                    aws s3api delete-bucket --bucket "$ARTIFACTS_LOCATION" --region "$CURRENT_REGION" --no-cli-pager &>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "S3バケット '$ARTIFACTS_LOCATION' が正常に削除されました！"
                    else
                        echo "エラー: S3バケット '$ARTIFACTS_LOCATION' の削除に失敗しました。権限を確認するか、本当に空であることを確認してください。"
                    fi
                else
                    echo "S3バケット '$ARTIFACTS_LOCATION' が見つからないか、既に削除されています。スキップします。"
                fi
            fi

            # --- IAMロールとポリシーの削除は実行しない ---
            echo "注意: 設定に従い、IAMロール '$SERVICE_ROLE_NAME' は削除されません。"
            # 設定に基づき、IAMロールは削除しません
            ;;

        *)
            echo "警告: 不明なアクション '$ACTION'。プロジェクトをスキップします: $PROJECT_NAME"
            ;;
    esac

    echo "--- プロジェクト: $PROJECT_NAME の処理が完了しました ---"
    echo "" # 空行を追加して見やすくする

done < "$CSV_FILE" # CSVファイルをwhileループの入力にする

echo "スクリプトが完了しました。"
