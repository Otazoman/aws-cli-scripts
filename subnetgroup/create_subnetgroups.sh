#!/bin/bash

# エラーチェック
if [ $# -ne 2 ]; then
  echo "Usage: $0 < rds | elasticache > csvfile.csv"
  exit 1
fi

SERVICE="$1"
CSV_FILE="$2"

if [ ! -f "$CSV_FILE" ]; then
  echo "エラー: CSVファイル $CSV_FILE が見つかりません"
  exit 1
fi

# サービスに応じたコマンド設定
if [ "$SERVICE" == "rds" ]; then
  CREATE_COMMAND="aws rds create-db-subnet-group"
  NAME_OPTION="--db-subnet-group-name"
  DESC_OPTION="--db-subnet-group-description"
  INFO_LABEL="RDS"
elif [ "$SERVICE" == "elasticache" ]; then
  CREATE_COMMAND="aws elasticache create-cache-subnet-group"
  NAME_OPTION="--cache-subnet-group-name"
  DESC_OPTION="--cache-subnet-group-description"
  INFO_LABEL="ElastiCache"
else
  echo "エラー: サポートされていないサービス '$SERVICE'（rds または elasticache を指定してください）"
  exit 1
fi

# メイン処理
echo "$INFO_LABEL サブネットグループを作成します..."
echo "使用ファイル: $CSV_FILE"

{
  echo "----------------------------------------"
  # ヘッダスキップ
  read -r header

  while IFS=',' read -r region name subnets description; do
    # UTF-8 BOM対策のため、行頭の不可視文字を削除
    region=$(echo "$region" | sed 's/^\xef\xbb\xbf//' | tr -d '[:space:]')
    name=$(echo "$name" | tr -d '[:space:]')
    subnets=$(echo "$subnets" | tr -d '\r') # Windows改行コード対応
    description=$(echo "$description" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # 空白行やヘッダー行の再処理を防ぐ（簡易チェック）
    if [ -z "$region" ] || [ "$region" == "REGION" ]; then
        continue
    fi


    if [ -z "$name" ]; then
        echo "エラー: サブネットグループ名が空白です。スキップします。"
        continue
    fi

    echo "処理中: $name (リージョン: $region)"
    echo "説明: $description"

    SUBNET_IDS=()
    IFS=';' read -ra subnet_items <<< "$subnets"

    for subnet_item in "${subnet_items[@]}"; do
        subnet_item=$(echo "$subnet_item" | tr -d '[:space:]')
        [ -z "$subnet_item" ] && continue

        if [[ $subnet_item == subnet-* ]]; then
        # サブネットIDの場合
        echo " サブネットIDを使用: $subnet_item"
        # サブネットIDが存在するか確認
        if ! aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet_item" >/dev/null 2>&1; then
            echo " エラー: サブネットID $subnet_item がリージョン $region に見つかりません。このサブネットはスキップします。"
            continue
        fi
        SUBNET_IDS+=("$subnet_item")
        else
        # サブネット名の場合
        echo " サブネット名から検索: $subnet_item (リージョン: $region)"
        # サブネット名からIDを検索 (tag:Nameを使用)
        subnet_id=$(aws ec2 describe-subnets \
            --region "$region" \
            --filters "Name=tag:Name,Values=$subnet_item" \
            --query "Subnets[].SubnetId" \
            --output text)
        
        if [ -z "$subnet_id" ]; then
            echo " エラー: サブネット名 '$subnet_item' がリージョン $region に見つかりません。このサブネットはスキップします。"
            continue
        fi
        SUBNET_IDS+=("$subnet_id")
        fi
    done

    # 有効なサブネットIDが一つも収集できなかった場合はスキップ
    if [ ${#SUBNET_IDS[@]} -eq 0 ]; then
        echo " 有効なサブネットが見つかりませんでした。このサブネットグループはスキップします。"
        echo "----------------------------------------"
        continue
    fi

    echo " 作成実行: $name (サブネット: ${SUBNET_IDS[*]})"

    # AWSコマンド実行
    if $CREATE_COMMAND \
        $NAME_OPTION "$name" \
        $DESC_OPTION "$description" \
        --subnet-ids "${SUBNET_IDS[@]}" \
        --region "$region" >/dev/null 2>&1; then
        echo " 作成成功: $name"
    else
        echo " 作成失敗: $name"
        echo "----------------------------------------"
        continue
    fi

    echo "----------------------------------------"
  done
} < "$CSV_FILE"

echo "処理が完了しました"

