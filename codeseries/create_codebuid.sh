#!/bin/bash

# CSVファイル名を引数から取得
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_csv_file>"
    echo "Example: $0 codebuild_projects.csv"
    exit 1
fi

CSV_FILE="$1" # 引数で渡されたファイル名を設定

# CSVファイルが存在するかチェック
if [ ! -f "$CSV_FILE" ]; then
    echo "Error: CSV file '$CSV_FILE' not found."
    exit 1
fi

IAM_POLICY_NAME_PREFIX="CodeBuildServicePolicy" # IAMポリシー名のプレフィックス
DEFAULT_AWS_REGION="ap-northeast-1" # デフォルトリージョン (CSVで指定がない場合)

# CodeBuildに必要なIAMポリシーJSON
# CloudWatch Logsへの書き込み、S3への読み書き、ECRへの読み取り、CodeCommitへの読み取り
# 必要に応じて権限を調整してください
CODEBUILD_ASSUME_ROLE_POLICY_DOC='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'

CODEBUILD_MANAGED_POLICY_DOC='{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:*:*:log-group:/aws/codebuild/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:GetBucketAcl",
                "s3:GetBucketLocation",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::*/*",
                "arn:aws:s3:::*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:GetRepositoryPolicy",
                "ecr:DescribeRepositories",
                "ecr:ListImages",
                "ecr:BatchGetImage",
                "ecr:GetAuthorizationToken"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "codecommit:GitPull"
            ],
            "Resource": "*"
        }
    ]
}'

echo "Starting CodeBuild project management script with CSV: $CSV_FILE"

# CSVファイルを読み込み、各行を処理
# IFS (Internal Field Separator) を変更してカンマ区切りで読み込む
# tail -n +2 でヘッダー行をスキップ
# ACTION列が追加されたため、read -r の変数を変更
cat "$CSV_FILE" | while IFS=, read -r ACTION PROJECT_NAME SOURCE_TYPE SOURCE_LOCATION IMAGE COMPUTE_TYPE ENVIRONMENT_TYPE SERVICE_ROLE_NAME BUILDSPEC ARTIFACTS_TYPE ARTIFACTS_LOCATION AWS_REGION_FROM_CSV; do

    # ヘッダー行をスキップ（空行やコメント行もスキップ）
    [[ "$ACTION" =~ ^ACTION$ ]] && continue
    [[ -z "$ACTION" ]] && continue # 空行スキップ

    CURRENT_REGION="${AWS_REGION_FROM_CSV:-$DEFAULT_AWS_REGION}" # CSVからリージョンを取得、なければデフォルト
    IAM_POLICY_NAME="${IAM_POLICY_NAME_PREFIX}-${SERVICE_ROLE_NAME}"

    echo "--- Processing ${ACTION} for project: $PROJECT_NAME (Region: $CURRENT_REGION) ---"

    case "$ACTION" in
        add)
            # --- IAMロールの存在確認と作成 ---
            echo "Checking IAM role: $SERVICE_ROLE_NAME in region $CURRENT_REGION..."
            SERVICE_ROLE_ARN=$(aws iam get-role --role-name "$SERVICE_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)

            if [ -z "$SERVICE_ROLE_ARN" ]; then
                echo "IAM role '$SERVICE_ROLE_NAME' not found. Creating..."
                SERVICE_ROLE_ARN=$(aws iam create-role \
                    --role-name "$SERVICE_ROLE_NAME" \
                    --assume-role-policy-document "$CODEBUILD_ASSUME_ROLE_POLICY_DOC" \
                    --query 'Role.Arn' \
                    --output text \
                    --region "$CURRENT_REGION" 2>/dev/null)

                if [ $? -ne 0 ]; then
                    echo "Error: Failed to create IAM role '$SERVICE_ROLE_NAME'. Skipping project."
                    continue
                fi
                echo "IAM role '$SERVICE_ROLE_NAME' created with ARN: $SERVICE_ROLE_ARN"

                # IAMポリシーを作成し、ロールにアタッチ
                IAM_POLICY_ARN=$(aws iam create-policy \
                    --policy-name "$IAM_POLICY_NAME" \
                    --policy-document "$CODEBUILD_MANAGED_POLICY_DOC" \
                    --query 'Policy.Arn' \
                    --output text \
                    --region "$CURRENT_REGION" 2>/dev/null)

                if [ $? -ne 0 ]; then
                    echo "Error: Failed to create IAM policy '$IAM_POLICY_NAME'. Skipping project."
                    continue
                fi
                echo "IAM policy '$IAM_POLICY_NAME' created with ARN: $IAM_POLICY_ARN"

                aws iam attach-role-policy \
                    --role-name "$SERVICE_ROLE_NAME" \
                    --policy-arn "$IAM_POLICY_ARN" \
                    --region "$CURRENT_REGION" 2>/dev/null

                if [ $? -ne 0 ]; then
                    echo "Error: Failed to attach policy '$IAM_POLICY_ARN' to role '$SERVICE_ROLE_NAME'. Skipping project."
                    continue
                fi
                echo "IAM policy attached to role '$SERVICE_ROLE_NAME'."
                # ロール作成・ポリシーアタッチ後の反映を待つために少し待機
                sleep 10
            else
                echo "IAM role '$SERVICE_ROLE_NAME' already exists with ARN: $SERVICE_ROLE_ARN"
            fi

            # --- S3バケットの存在確認と作成 ---
            if [[ "$ARTIFACTS_TYPE" == "S3" && -n "$ARTIFACTS_LOCATION" ]]; then
                echo "Checking S3 bucket: $ARTIFACTS_LOCATION in region $CURRENT_REGION..."
                aws s3api head-bucket --bucket "$ARTIFACTS_LOCATION" --region "$CURRENT_REGION" &>/dev/null

                if [ $? -ne 0 ]; then
                    echo "S3 bucket '$ARTIFACTS_LOCATION' not found in region '$CURRENT_REGION'. Creating..."
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
                        echo "Error: Failed to create S3 bucket '$ARTIFACTS_LOCATION' in region '$CURRENT_REGION'. Skipping project."
                        continue
                    fi
                    echo "S3 bucket '$ARTIFACTS_LOCATION' created successfully."
                else
                    echo "S3 bucket '$ARTIFACTS_LOCATION' already exists."
                fi
            fi

            # --- CodeBuildプロジェクトの作成 ---
            echo "Creating CodeBuild project: $PROJECT_NAME..."

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
                --description "CodeBuild project for $PROJECT_NAME created via script." \
                --region "$CURRENT_REGION" \
                --no-cli-pager 2>/dev/null

            if [ $? -eq 0 ]; then
                echo "Project '$PROJECT_NAME' created successfully!"
            else
                echo "Error: Failed to create project '$PROJECT_NAME'. It might already exist or there's another issue."
            fi
            ;;

        remove)
            # --- CodeBuildプロジェクトの削除 ---
            echo "Attempting to delete CodeBuild project: $PROJECT_NAME in region $CURRENT_REGION..."
            aws codebuild delete-project --name "$PROJECT_NAME" --region "$CURRENT_REGION" --no-cli-pager &>/dev/null

            if [ $? -eq 0 ]; then
                echo "CodeBuild project '$PROJECT_NAME' deleted successfully!"
            else
                echo "CodeBuild project '$PROJECT_NAME' not found or failed to delete. Skipping."
            fi

            # --- S3バケットの削除 ---
            if [[ "$ARTIFACTS_TYPE" == "S3" && -n "$ARTIFACTS_LOCATION" ]]; then
                echo "Attempting to delete S3 bucket: $ARTIFACTS_LOCATION in region $CURRENT_REGION..."
                aws s3api head-bucket --bucket "$ARTIFACTS_LOCATION" --region "$CURRENT_REGION" &>/dev/null

                if [ $? -eq 0 ]; then
                    echo "S3 bucket '$ARTIFACTS_LOCATION' exists. Deleting contents first..."
                    aws s3 rm "s3://$ARTIFACTS_LOCATION" --recursive --region "$CURRENT_REGION" --no-cli-pager &>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "S3 bucket '$ARTIFACTS_LOCATION' contents deleted."
                    else
                        echo "Warning: Failed to delete contents of S3 bucket '$ARTIFACTS_LOCATION'. Might be empty or permissions issue."
                    fi

                    aws s3api delete-bucket --bucket "$ARTIFACTS_LOCATION" --region "$CURRENT_REGION" --no-cli-pager &>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "S3 bucket '$ARTIFACTS_LOCATION' deleted successfully!"
                    else
                        echo "Error: Failed to delete S3 bucket '$ARTIFACTS_LOCATION'. Check permissions or if it's truly empty."
                    fi
                else
                    echo "S3 bucket '$ARTIFACTS_LOCATION' not found or already deleted. Skipping."
                fi
            fi

            # --- IAMロールとポリシーの削除 ---
            echo "Attempting to delete IAM role: $SERVICE_ROLE_NAME and its policy in region $CURRENT_REGION..."
            SERVICE_ROLE_ARN=$(aws iam get-role --role-name "$SERVICE_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)

            if [ -n "$SERVICE_ROLE_ARN" ]; then
                IAM_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${IAM_POLICY_NAME}'].Arn" --output text --region "$CURRENT_REGION" 2>/dev/null)

                if [ -n "$IAM_POLICY_ARN" ]; then
                    echo "Detaching policy '$IAM_POLICY_NAME' from role '$SERVICE_ROLE_NAME'..."
                    aws iam detach-role-policy \
                        --role-name "$SERVICE_ROLE_NAME" \
                        --policy-arn "$IAM_POLICY_ARN" \
                        --region "$CURRENT_REGION" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "Policy detached."
                    else
                        echo "Warning: Failed to detach policy. It might already be detached."
                    fi

                    echo "Deleting policy '$IAM_POLICY_NAME'..."
                    aws iam delete-policy --policy-arn "$IAM_POLICY_ARN" --region "$CURRENT_REGION" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo "Policy '$IAM_POLICY_NAME' deleted successfully!"
                    else
                        echo "Warning: Failed to delete policy '$IAM_POLICY_NAME'. It might be in use or already deleted."
                    fi
                else
                    echo "IAM policy '$IAM_POLICY_NAME' not found. Skipping policy deletion."
                fi

                echo "Deleting IAM role '$SERVICE_ROLE_NAME'..."
                aws iam delete-role --role-name "$SERVICE_ROLE_NAME" --region "$CURRENT_REGION" 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo "IAM role '$SERVICE_ROLE_NAME' deleted successfully!"
                else
                    echo "Error: Failed to delete IAM role '$SERVICE_ROLE_NAME'. It might have other policies attached or be in use."
                fi
            else
                echo "IAM role '$SERVICE_ROLE_NAME' not found or already deleted. Skipping role deletion."
            fi
            ;;

        *)
            echo "Warning: Unknown ACTION '$ACTION'. Skipping project: $PROJECT_NAME."
            ;;
    esac

    echo "--- Finished processing project: $PROJECT_NAME ---"
    echo "" # 空行を追加して見やすくする

done < "$CSV_FILE" # CSVファイルをwhileループの入力にする

echo "Script finished."
