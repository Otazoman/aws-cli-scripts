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

tail -n +2 "$CSV_FILE" | while IFS=, read -r Action BucketName Region VersioningEnabled PublicAccessBlock IntelligentTiering LifecycleConfigFile PolicyFile Tags RemoveObjects
do
    # バケット存在チェック
    if aws s3api head-bucket --bucket "$BucketName" 2>/dev/null; then
        echo "バケット $BucketName は既に存在します"
    else
        echo "バケット $BucketName は存在しません"
    fi

    case "$Action" in
        "add")
            echo "■バケット追加/更新処理開始: $BucketName"
            
            # バケット作成（存在しない場合）
            if ! aws s3api head-bucket --bucket "$BucketName" 2>/dev/null; then
                echo "バケット作成中: $BucketName (リージョン: $Region)"
                aws s3api create-bucket \
                    --bucket "$BucketName" \
                    --region "$Region" \
                    --create-bucket-configuration LocationConstraint="$Region"
            else
                echo "バケットは既に存在するため作成をスキップします"
            fi

            # パブリックアクセスブロック設定 (空欄やnullなら適用しない)
            if [ -n "$PublicAccessBlock" ] && [ "$PublicAccessBlock" != "null" ]; then
                echo "パブリックアクセスブロック設定中..."
                aws s3api put-public-access-block \
                    --bucket "$BucketName" \
                    --public-access-block-configuration "BlockPublicAcls=$PublicAccessBlock,IgnorePublicAcls=$PublicAccessBlock,BlockPublicPolicy=$PublicAccessBlock,RestrictPublicBuckets=$PublicAccessBlock"
            fi

            # バージョニング設定
            if [ "$VersioningEnabled" = "true" ]; then
                echo "バージョニングを有効化しています"
                aws s3api put-bucket-versioning \
                    --bucket "$BucketName" \
                    --versioning-configuration Status=Enabled
            fi

            # Intelligent-Tiering設定
            if [ "$IntelligentTiering" = "true" ]; then
                echo "Intelligent-Tieringを設定中..."
                aws s3api put-bucket-intelligent-tiering-configuration \
                    --bucket "$BucketName" \
                    --id "archive-config" \
                    --intelligent-tiering-configuration '{
                        "Id": "archive-config",
                        "Status": "Enabled",
                        "Tierings": [
                            {"Days": 90, "AccessTier": "ARCHIVE_ACCESS"}
                        ]
                    }' > /dev/null
            fi

            # バケットポリシー適用
            if [ -n "$PolicyFile" ] && [ "$PolicyFile" != "null" ] && [ -f "$PolicyFile" ]; then
                echo "バケットポリシーを適用中..."
                aws s3api put-bucket-policy \
                    --bucket "$BucketName" \
                    --policy "file://$PolicyFile"
            fi

            # ライフサイクル設定
            if [ -n "$LifecycleConfigFile" ] && [ "$LifecycleConfigFile" != "null" ] && [ -f "$LifecycleConfigFile" ]; then
                echo "ライフサイクル設定を適用中..."
                aws s3api put-bucket-lifecycle-configuration \
                    --bucket "$BucketName" \
                    --lifecycle-configuration "file://$LifecycleConfigFile"
            fi

            # タグ設定
            if [ -n "$Tags" ] && [ "$Tags" != "null" ]; then
                echo "タグを設定中..."
                TAG_JSON="{\"TagSet\": ["
                IFS=';' read -ra TAG_PAIRS <<< "$Tags"
                for pair in "${TAG_PAIRS[@]}"; do
                    IFS='=' read -r key value <<< "$pair"
                    key=$(echo "$key" | tr -d '"' | xargs)
                    value=$(echo "$value" | tr -d '"' | xargs)
                    TAG_JSON+="{\"Key\":\"$key\",\"Value\":\"$value\"},"
                done
                TAG_JSON="${TAG_JSON%,}]}"
                
                aws s3api put-bucket-tagging \
                    --bucket "$BucketName" \
                    --tagging "$TAG_JSON"
            fi

            echo "✅ $BucketName の追加/更新処理が完了しました"
            ;;

        "remove")
            echo "■バケット削除処理開始: $BucketName"
            
            if aws s3api head-bucket --bucket "$BucketName" 2>/dev/null; then
                if [ "$RemoveObjects" = "true" ]; then
                    echo "バケット内オブジェクトを削除中..."
                    aws s3 rm "s3://$BucketName" --recursive
                fi
                
                echo "バケットを削除中..."
                aws s3api delete-bucket --bucket "$BucketName"
                echo "✅ $BucketName の削除が完了しました"
            else
                echo "⚠ $BucketName は存在しないため削除をスキップします"
            fi
            ;;

        *)
            echo "⚠ 不明なアクション: $Action (スキップします)"
            ;;
    esac

    echo "----------------------------------------------"
done

echo "全ての処理が完了しました"

