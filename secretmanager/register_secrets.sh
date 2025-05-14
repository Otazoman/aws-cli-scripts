#!/bin/bash

CSV_FILE="$1"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "CSVファイルが見つかりません: $CSV_FILE"
  exit 1
fi

# ヘッダを除いて1行ずつ処理
tail -n +2 "$CSV_FILE" | while IFS=',' read -r REGION NAME DESCRIPTION SECRET_FILE TAGS; do
  if [[ -z "$REGION" || -z "$NAME" || -z "$SECRET_FILE" ]]; then
    echo "スキップ（REGION/NAME/SECRET_FILE が空）: $NAME"
    continue
  fi

  if [[ ! -f "$SECRET_FILE" ]]; then
    echo "シークレットファイルが見つかりません: $SECRET_FILE"
    continue
  fi
  SECRET_STRING=$(cat "$SECRET_FILE")

  # タグの整形
  TAGS_JSON="[]"
  if [[ -n "$TAGS" ]]; then
    TAGS_JSON=$(echo "$TAGS" | awk -F';' '{
      printf "["
      for (i = 1; i <= NF; i += 2) {
        if (i > 1) printf ","
        key=gensub(/^Key=/, "", "g", $i)
        val=gensub(/^Value=/, "", "g", $(i+1))
        printf "{\"Key\":\"" key "\",\"Value\":\"" val "\"}"
      }
      printf "]"
    }')
  fi

  # 存在確認
  aws secretsmanager describe-secret --secret-id "$NAME" --region "$REGION" > /dev/null 2>&1
  if [[ $? -eq 0 ]]; then
    echo "更新中: $NAME ($REGION)"

    aws secretsmanager update-secret \
      --secret-id "$NAME" \
      --description "$DESCRIPTION" \
      --secret-string "$SECRET_STRING" \
      --region "$REGION"

    if [[ $? -eq 0 ]]; then
      echo "更新成功: $NAME"
    else
      echo "更新失敗: $NAME"
    fi
  else
    echo "新規作成中: $NAME ($REGION)"

    aws secretsmanager create-secret \
      --name "$NAME" \
      --description "$DESCRIPTION" \
      --secret-string "$SECRET_STRING" \
      --tags "$TAGS_JSON" \
      --region "$REGION"

    if [[ $? -eq 0 ]]; then
      echo "作成成功: $NAME"
    else
      echo "作成失敗: $NAME"
    fi
  fi

done

