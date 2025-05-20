#!/bin/bash

# CSVファイルの指定チェック
if [ $# -ne 1 ]; then
    echo "Usage: $0 <csv_file>"
    exit 1
fi

CSV_FILE="$1"

# CSVファイルの存在確認
if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: 指定されたCSVファイルが見つかりません: $CSV_FILE"
    exit 1
fi

# 処理開始
echo "IAMリソース管理処理を開始します"
echo "使用するCSVファイル: $CSV_FILE"

# CSVを読み込みながら処理
{
    # ヘッダー行を読み飛ばす
    tail -n +2 "$CSV_FILE" | awk '{ sub(/\r$/, ""); print }' | while IFS=, read -r ACTION RESOURCE_TYPE RESOURCE_NAME POLICY_DOCUMENT_PATH ATTACH_TO IS_ADD_ATTACH TAGS
    do

        if [ -z "$ACTION" ] || [ -z "$RESOURCE_TYPE" ]; then
            echo "警告: ACTION または RESOURCE_TYPE が空の行をスキップします"
            echo $ACTION $RESOURCE_TYPE
            continue
        fi

        echo "処理中: [$ACTION] $RESOURCE_TYPE $RESOURCE_NAME"

        # タグを処理
        TAG_ARGS=""
        if [ -n "$TAGS" ]; then
            IFS=, read -ra TAG_PAIRS <<< "$TAGS"
            for pair in "${TAG_PAIRS[@]}"
            do
                KEY=$(echo "$pair" | cut -d'=' -f1)
                VALUE=$(echo "$pair" | cut -d'=' -f2)
                TAG_ARGS="$TAG_ARGS Key=$KEY,Value=$VALUE"
            done
        fi

        case "$ACTION-$RESOURCE_TYPE" in
            "add-POLICY")
                # POLICY_DOCUMENT_PATHが空の場合はスキップ
                if [ -z "$POLICY_DOCUMENT_PATH" ]; then
                    echo "警告: POLICY_DOCUMENT_PATHが空のため、ポリシー $RESOURCE_NAME の処理をスキップします"
                    continue
                fi
                
                # ポリシー作成または更新
                if aws iam get-policy --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$RESOURCE_NAME" &>/dev/null; then
                    echo "ポリシー $RESOURCE_NAME は既に存在します。更新します..."
                    # 新しいバージョンを作成
                    aws iam create-policy-version \
                        --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$RESOURCE_NAME" \
                        --policy-document "file://$POLICY_DOCUMENT_PATH" \
                        --set-as-default \
                        --no-cli-pager
                else
                    echo "新しいポリシー $RESOURCE_NAME を作成します"
                    aws iam create-policy \
                        --policy-name "$RESOURCE_NAME" \
                        --policy-document "file://$POLICY_DOCUMENT_PATH" \
                        --tags $TAG_ARGS \
                        --no-cli-pager
                fi
                ;;

            "remove-POLICY")
                echo "ポリシー $RESOURCE_NAME を削除します"
                POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$RESOURCE_NAME"

                # グループに関連付けられているかチェック
                attached_groups=$(aws iam list-entities-for-policy \
                    --policy-arn "$POLICY_ARN" \
                    --query 'PolicyGroups[].GroupName' --output text)

                if [ -n "$attached_groups" ]; then
                    echo "警告: ポリシー $RESOURCE_NAME は以下のIAMグループにアタッチされています。削除をスキップします: $attached_groups"
                    continue
                fi

                # すべてのバージョンを削除
                for version in $(aws iam list-policy-versions --policy-arn $POLICY_ARN --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
                    aws iam delete-policy-version --policy-arn $POLICY_ARN --version-id $version --no-cli-pager
                done
                # ポリシーをデタッチ
                for entity in $(aws iam list-entities-for-policy --policy-arn $POLICY_ARN --query 'PolicyRoles[].RoleName' --output text); do
                    aws iam detach-role-policy --role-name $entity --policy-arn $POLICY_ARN --no-cli-pager
                done
                for entity in $(aws iam list-entities-for-policy --policy-arn $POLICY_ARN --query 'PolicyUsers[].UserName' --output text); do
                    aws iam detach-user-policy --user-name $entity --policy-arn $POLICY_ARN --no-cli-pager
                done
                # ポリシーを削除
                aws iam delete-policy --policy-arn $POLICY_ARN --no-cli-pager
                ;;

            "add-ROLE")
                # IAMロール作成 (既にある場合はスキップ)
                if aws iam get-role --role-name "$RESOURCE_NAME" &>/dev/null; then
                    echo "ロール $RESOURCE_NAME は既に存在します。作成をスキップします。"
                else
                    # POLICY_DOCUMENT_PATHが空の場合はスキップ
                    if [ -z "$POLICY_DOCUMENT_PATH" ]; then
                        echo "エラー: ロール作成にはPOLICY_DOCUMENT_PATH（信頼ポリシー）が必要です"
                        continue
                    fi
                    
                    echo "ロール $RESOURCE_NAME を作成します"
                    aws iam create-role \
                        --role-name "$RESOURCE_NAME" \
                        --assume-role-policy-document "file://$POLICY_DOCUMENT_PATH" \
                        --tags $TAG_ARGS \
                        --no-cli-pager
                fi

                # ポリシーアタッチ
                if [ -n "$ATTACH_TO" ]; then
                    if [ "$IS_ADD_ATTACH" == "TRUE" ]; then
                        echo "追加でポリシー $ATTACH_TO をロール $RESOURCE_NAME にアタッチします"
                    else
                        # 既存のポリシーをデタッチ (フルアタッチの場合)
                        attached_policies=$(aws iam list-attached-role-policies --role-name "$RESOURCE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text)
                        for policy in $attached_policies; do
                            aws iam detach-role-policy \
                                --role-name "$RESOURCE_NAME" \
                                --policy-arn "$policy" \
                                --no-cli-pager
                        done
                        echo "ポリシー $ATTACH_TO をロール $RESOURCE_NAME にアタッチします (フルアタッチ)"
                    fi

                    # ポリシーARNを判定（AWS管理ポリシーかカスタマー管理ポリシーか）
                    if [[ "$ATTACH_TO" == arn:aws:iam::* ]]; then
                        POLICY_ARN="$ATTACH_TO"
                    else
                        POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$ATTACH_TO"
                    fi

                    aws iam attach-role-policy \
                        --role-name "$RESOURCE_NAME" \
                        --policy-arn "$POLICY_ARN" \
                        --no-cli-pager
                fi
                ;;

            "remove-ROLE")
                echo "ロール $RESOURCE_NAME を削除します"

                #　存在チェック
                if ! aws iam get-role --role-name "$RESOURCE_NAME" &>/dev/null; then
                    echo "ロール $RESOURCE_NAME は存在しません。スキップします。"
                    continue
                fi

                # インスタンスプロファイルからロールを削除
                for profile in $(aws iam list-instance-profiles-for-role --role-name $RESOURCE_NAME --query 'InstanceProfiles[].InstanceProfileName' --output text); do
                    aws iam remove-role-from-instance-profile \
                        --instance-profile-name $profile \
                        --role-name $RESOURCE_NAME \
                        --no-cli-pager
                done
                # ポリシーをデタッチ
                for policy in $(aws iam list-attached-role-policies --role-name $RESOURCE_NAME --query 'AttachedPolicies[].PolicyArn' --output text); do
                    aws iam detach-role-policy \
                        --role-name $RESOURCE_NAME \
                        --policy-arn $policy \
                        --no-cli-pager
                done
                # ロールを削除
                aws iam delete-role --role-name $RESOURCE_NAME
                ;;

            "add-USER")
                # IAMユーザー作成 (既にある場合はスキップ)
                if aws iam get-user --user-name "$RESOURCE_NAME" &>/dev/null; then
                    echo "ユーザー $RESOURCE_NAME は既に存在します。作成をスキップします。"
                else
                    echo "ユーザー $RESOURCE_NAME を作成します"
                    aws iam create-user \
                        --user-name "$RESOURCE_NAME" \
                        --tags $TAG_ARGS \
                        --no-cli-pager
                fi

                # ポリシーアタッチ
                if [ -n "$ATTACH_TO" ]; then
                    if [ "$IS_ADD_ATTACH" == "TRUE" ]; then
                        echo "追加でポリシー $ATTACH_TO をユーザー $RESOURCE_NAME にアタッチします"
                    else
                        # 既存のポリシーをデタッチ (フルアタッチの場合)
                        attached_policies=$(aws iam list-attached-user-policies --user-name "$RESOURCE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text)
                        for policy in $attached_policies; do
                            aws iam detach-user-policy \
                                --user-name "$RESOURCE_NAME" \
                                --policy-arn "$policy" \
                                --no-cli-pager
                        done
                        echo "ポリシー $ATTACH_TO をユーザー $RESOURCE_NAME にアタッチします (フルアタッチ)"
                    fi

                    # ポリシーARNを判定（AWS管理ポリシーかカスタマー管理ポリシーか）
                    if [[ "$ATTACH_TO" == arn:aws:iam::* ]]; then
                        POLICY_ARN="$ATTACH_TO"
                    else
                        POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$ATTACH_TO"
                    fi

                    aws iam attach-user-policy \
                        --user-name "$RESOURCE_NAME" \
                        --policy-arn "$POLICY_ARN" \
                        --no-cli-pager
                fi
                ;;

            "remove-USER")
                echo "ユーザー $RESOURCE_NAME を削除します"

                #　存在チェック
                if ! aws iam get-user --user-name "$RESOURCE_NAME" &>/dev/null; then
                    echo "ユーザ $RESOURCE_NAME は存在しません。スキップします。"
                    continue
                fi

                # ポリシーをデタッチ
                for policy in $(aws iam list-attached-user-policies --user-name $RESOURCE_NAME --query 'AttachedPolicies[].PolicyArn' --output text); do
                    aws iam detach-user-policy \
                        --user-name $RESOURCE_NAME \
                        --policy-arn $policy \
                        --no-cli-pager
                done
                # ユーザーを削除
                aws iam delete-user --user-name $RESOURCE_NAME --no-cli-pager
                ;;

            "add-INSTANCE_PROFILE")
                # インスタンスプロファイル作成 (既にある場合はスキップ)
                if aws iam get-instance-profile --instance-profile-name "$RESOURCE_NAME" &>/dev/null; then
                    echo "インスタンスプロファイル $RESOURCE_NAME は既に存在します。作成をスキップします。"
                else
                    echo "インスタンスプロファイル $RESOURCE_NAME を作成します"
                    aws iam create-instance-profile \
                        --instance-profile-name "$RESOURCE_NAME" \
                        --tags $TAG_ARGS \
                        --no-cli-pager
                fi
                
                # ロールをアタッチ（ATTACH_TOが指定されている場合）
                if [ -n "$ATTACH_TO" ]; then
                    echo "ロール $ATTACH_TO をインスタンスプロファイル $RESOURCE_NAME にアタッチします"
                    aws iam add-role-to-instance-profile \
                        --instance-profile-name "$RESOURCE_NAME" \
                        --role-name "$ATTACH_TO" \
                        --no-cli-pager
                fi
                ;;

            "remove-INSTANCE_PROFILE")
                echo "インスタンスプロファイル $RESOURCE_NAME を削除します"

                # 存在チェック
                if ! aws iam get-instance-profile --instance-profile-name "$RESOURCE_NAME" &>/dev/null; then
                    echo "インスタンスプロファイル $RESOURCE_NAME は存在しません。スキップします。"
                    continue
                fi

                # ロールをデタッチ
                for role in $(aws iam list-instance-profiles-for-role --role-name $ATTACH_TO --query 'InstanceProfiles[].InstanceProfileName' --output text); do
                    aws iam remove-role-from-instance-profile \
                        --instance-profile-name $RESOURCE_NAME \
                        --role-name $role \
                        --no-cli-pager
                done
                # インスタンスプロファイルを削除
                aws iam delete-instance-profile --instance-profile-name $RESOURCE_NAME
                ;;
                
            *)
                echo "警告: 不明なアクションまたはリソースタイプ [$ACTION-$RESOURCE_TYPE] はスキップされます"
                ;;
        esac

    done
} < "$CSV_FILE"

echo "すべての処理が完了しました。"

