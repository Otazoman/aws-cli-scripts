#!/bin/bash

# CSVファイルの指定を必須化
if [ -z "$1" ]; then
    echo "エラー: CSVファイルを指定してください"
    exit 1
fi
CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: 指定されたCSVファイルが存在しません: $CSV_FILE"
    exit 1
fi

# ヘッダーチェック
HEADER=$(head -1 "$CSV_FILE")
EXPECTED_HEADER="ACTION,BUCKETNAME,REGION,VERSIONINGENABLED,PUBLICACCESSBLOCK,INTELLIGENTTIERING,LIFECYCLECONFIGFILE,POLICYFILE,TAGS,REMOVEOBJECTS"

if [ "${HEADER^^}" != "$EXPECTED_HEADER" ]; then
    echo "エラー: CSVヘッダーが期待する形式と一致しません"
    echo "期待される形式: $EXPECTED_HEADER"
    echo "実際のヘッダー: $HEADER"
    exit 1
fi

tail -n +2 "$CSV_FILE" | while IFS=, read -r ACTION BUCKETNAME REGION VERSIONINGENABLED PUBLICACCESSBLOCK INTELLIGENTTIERING LIFECYCLECONFIGFILE POLICYFILE TAGS REMOVEOBJECTS
do
    # 変数の前後の空白をトリム
    ACTION=$(echo "$ACTION" | xargs)
    BUCKETNAME=$(echo "$BUCKETNAME" | xargs)
    REGION=$(echo "$REGION" | xargs)
    VERSIONINGENABLED=$(echo "$VERSIONINGENABLED" | xargs)
    PUBLICACCESSBLOCK=$(echo "$PUBLICACCESSBLOCK" | xargs)
    INTELLIGENTTIERING=$(echo "$INTELLIGENTTIERING" | xargs)
    LIFECYCLECONFIGFILE=$(echo "$LIFECYCLECONFIGFILE" | xargs)
    POLICYFILE=$(echo "$POLICYFILE" | xargs)
    TAGS=$(echo "$TAGS" | xargs)
    REMOVEOBJECTS=$(echo "$REMOVEOBJECTS" | xargs)

    # バケット存在チェック
    if aws s3api head-bucket --bucket "$BUCKETNAME" 2>/dev/null; then
        echo "バケット $BUCKETNAME は既に存在します"
    else
        echo "バケット $BUCKETNAME は存在しません"
    fi

    case "$ACTION" in
        "add")
            echo "■バケット追加/更新処理開始: $BUCKETNAME"
            
            # バケット作成（存在しない場合）
            if ! aws s3api head-bucket --bucket "$BUCKETNAME" 2>/dev/null; then
                echo "バケット作成中: $BUCKETNAME (リージョン: $REGION)"
                if [ "$REGION" = "us-east-1" ]; then
                    aws s3api create-bucket \
                        --bucket "$BUCKETNAME" \
                        --region "$REGION"
                else
                    aws s3api create-bucket \
                        --bucket "$BUCKETNAME" \
                        --region "$REGION" \
                        --create-bucket-configuration LocationConstraint="$REGION"
                fi
            else
                echo "バケットは既に存在するため作成をスキップします"
            fi

            # パブリックアクセスブロック設定 (TRUE=ON, FALSE=OFF, null/空=無視)
            if [ "$PUBLICACCESSBLOCK" = "TRUE" ]; then
                echo "パブリックアクセスブロックを有効化中..."
                aws s3api put-public-access-block \
                    --bucket "$BUCKETNAME" \
                    --public-access-block-configuration '{
                        "BlockPublicAcls": true,
                        "IgnorePublicAcls": true,
                        "BlockPublicPolicy": true,
                        "RestrictPublicBuckets": true
                    }'
            elif [ "$PUBLICACCESSBLOCK" = "FALSE" ]; then
                echo "パブリックアクセスブロックを無効化中..."
                aws s3api put-public-access-block \
                    --bucket "$BUCKETNAME" \
                    --public-access-block-configuration '{
                        "BlockPublicAcls": false,
                        "IgnorePublicAcls": false,
                        "BlockPublicPolicy": false,
                        "RestrictPublicBuckets": false
                    }'
            fi

            # バージョニング設定
            if [ "$VERSIONINGENABLED" = "TRUE" ]; then
                echo "バージョニングを有効化しています"
                aws s3api put-bucket-versioning \
                    --bucket "$BUCKETNAME" \
                    --versioning-configuration Status=Enabled
            fi

            # Intelligent-Tiering設定

            if [ -n "$INTELLIGENTTIERING" ] && [ "$INTELLIGENTTIERING" != "null" ] && [ -f "$INTELLIGENTTIERING" ]; then
                echo "Intelligent-Tieringを設定中..."
                TIERINGS_JSON=$(jq -c '.' "$INTELLIGENTTIERING")
                aws s3api put-bucket-intelligent-tiering-configuration \
                    --bucket "$BUCKETNAME" \
                    --id "archive-config" \
                    --intelligent-tiering-configuration "$(jq -nc --argjson tierings "$TIERINGS_JSON" '{
                        "Id": "archive-config",
                        "Status": "Enabled",
                        "Tierings": $tierings
                    }')"
            fi

            # バケットポリシー適用
            if [ -n "$POLICYFILE" ] && [ "$POLICYFILE" != "null" ] && [ -f "$POLICYFILE" ]; then
                echo "バケットポリシーを適用中..."
                aws s3api put-bucket-policy \
                    --bucket "$BUCKETNAME" \
                    --policy "file://$POLICYFILE"
            fi

            # ライフサイクル設定
            if [ -n "$LIFECYCLECONFIGFILE" ] && [ "$LIFECYCLECONFIGFILE" != "null" ] && [ -f "$LIFECYCLECONFIGFILE" ]; then
                echo "ライフサイクル設定を適用中..."
                aws s3api put-bucket-lifecycle-configuration \
                    --bucket "$BUCKETNAME" \
                    --lifecycle-configuration "file://$LIFECYCLECONFIGFILE"
            fi

            # タグ設定
            if [ -n "$TAGS" ] && [ "$TAGS" != "null" ]; then
                echo "タグを設定中..."
                TAG_JSON="{\"TagSet\": ["
                IFS=';' read -ra TAG_PAIRS <<< "$TAGS"
                for pair in "${TAG_PAIRS[@]}"; do
                    IFS='=' read -r key value <<< "$pair"
                    key=$(echo "$key" | tr -d '"' | xargs)
                    value=$(echo "$value" | tr -d '"' | xargs)
                    TAG_JSON+="{\"Key\":\"$key\",\"Value\":\"$value\"},"
                done
                TAG_JSON="${TAG_JSON%,}]}"
                
                aws s3api put-bucket-tagging \
                    --bucket "$BUCKETNAME" \
                    --tagging "$TAG_JSON"
            fi

            echo "✅ $BUCKETNAME の追加/更新処理が完了しました"
            ;;

        "remove")
            echo "■バケット削除処理開始: $BUCKETNAME"
            
            if aws s3api head-bucket --bucket "$BUCKETNAME" 2>/dev/null; then
                if [ "$REMOVEOBJECTS" = "TRUE" ]; then
                    echo "バケット内オブジェクトを削除中..."
                    aws s3 rm "s3://$BUCKETNAME" --recursive
                fi
                
                echo "バケットを削除中..."
                aws s3api delete-bucket --bucket "$BUCKETNAME"
                echo "✅ $BUCKETNAME の削除が完了しました"
            else
                echo "⚠ $BUCKETNAME は存在しないため削除をスキップします"
            fi
            ;;

        *)
            echo "⚠ 不明なアクション: $ACTION (スキップします)"
            ;;
    esac

    echo "----------------------------------------------"
done

echo "全ての処理が完了しました"
