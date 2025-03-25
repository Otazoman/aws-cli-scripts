#!/bin/bash

# 簡単なエラーチェック
if [ $# -ne 1 ]; then
  echo "Usage: $0 csvfile.csv"
  exit 1
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
  echo "エラー: CSVファイル $CSV_FILE が見つかりません"
  exit 1
fi

# メイン処理
{
  echo "RDSサブネットグループを作成します..."
  echo "使用ファイル: $CSV_FILE"
  echo "----------------------------------------"

  # ヘッダ行をスキップ
  read -r header

  while IFS=',' read -r region name subnets description; do
    # リージョン設定を確認
    if [ -z "$region" ]; then
      echo "エラー: リージョンが指定されていません。スキップします。"
      continue
    fi

    echo "処理中: $name (リージョン: $region)"
    echo "説明: $description"

    SUBNET_IDS=()
    IFS=';' read -ra subnet_items <<< "$subnets"
    
    for subnet_item in "${subnet_items[@]}"; do
      subnet_item=$(echo "$subnet_item" | tr -d '\r' | xargs)
      [ -z "$subnet_item" ] && continue

      if [[ $subnet_item == subnet-* ]]; then
        echo " サブネットIDを使用: $subnet_item"
        if ! aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet_item" >/dev/null 2>&1; then
          echo " エラー: サブネットID $subnet_item がリージョン $region に見つかりません"
          continue 2
        fi
        SUBNET_IDS+=("$subnet_item")
      else
        echo " サブネット名から検索: $subnet_item (リージョン: $region)"
        subnet_id=$(aws ec2 describe-subnets \
          --region "$region" \
          --filters "Name=tag:Name,Values=$subnet_item" \
          --query "Subnets[].SubnetId" \
          --output text | tr -d '\r')
        
        if [ -z "$subnet_id" ]; then
          echo " エラー: サブネット名 '$subnet_item' がリージョン $region に見つかりません"
          continue 2
        fi
        SUBNET_IDS+=("$subnet_id")
      fi
    done

    if [ ${#SUBNET_IDS[@]} -eq 0 ]; then
      echo " 有効なサブネットが見つかりませんでした。スキップします。"
      continue
    fi

    echo " 作成実行: $name (サブネット: ${SUBNET_IDS[*]})"
    
    if aws rds create-db-subnet-group \
      --db-subnet-group-name "$name" \
      --db-subnet-group-description "$description" \
      --subnet-ids "${SUBNET_IDS[@]}" \
      --region "$region" >/dev/null 2>&1; then
      echo " 作成成功: $name"
    else
      echo " 作成失敗: $name"
    fi
    
    echo "----------------------------------------"
  done

  echo "処理が完了しました"
} < "$CSV_FILE"
