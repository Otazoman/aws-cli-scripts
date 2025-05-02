#!/bin/bash

# 📌 必須引数: CSVファイル
if [[ -z "$1" ]]; then
  echo "エラー: CSVファイルパスを指定してください。"
  echo "使い方: $0 <option_group_config.csv>"
  exit 1
fi

CONFIG_CSV="$1"

if [[ ! -f "$CONFIG_CSV" ]]; then
  echo "エラー: 指定されたCSVファイルが存在しません: $CONFIG_CSV"
  exit 1
fi

# ヘッダーをスキップして読み込み（1行目はREGION,...を想定）
tail -n +2 "$CONFIG_CSV" | while IFS=',' read -r REGION OPTION_GROUP_NAME ENGINE_NAME ENGINE_VERSION DESCRIPTION OPTIONS_JSON_PATH; do
  echo "----------------------------------------"
  echo "▶ リージョン: $REGION"
  echo "▶ オプショングループ名: $OPTION_GROUP_NAME"
  echo "▶ エンジン: $ENGINE_NAME ($ENGINE_VERSION)"
  echo "▶ 説明: $DESCRIPTION"
  echo "▶ オプションファイル: $OPTIONS_JSON_PATH"

  if [[ ! -f "$OPTIONS_JSON_PATH" ]]; then
    echo "⚠ エラー: 指定されたオプションJSONファイルが見つかりません: $OPTIONS_JSON_PATH"
    continue
  fi

  # オプショングループの存在確認
  EXISTS=$(aws rds describe-option-groups \
    --region "$REGION" \
    --option-group-name "$OPTION_GROUP_NAME" \
    --query "OptionGroupsList[0].OptionGroupName" \
    --output text 2>/dev/null)

  if [[ "$EXISTS" == "None" || -z "$EXISTS" ]]; then
    echo "✅ オプショングループを作成中..."
    aws rds create-option-group \
      --region "$REGION" \
      --option-group-name "$OPTION_GROUP_NAME" \
      --engine-name "$ENGINE_NAME" \
      --major-engine-version "$ENGINE_VERSION" \
      --option-group-description "$DESCRIPTION" \
      --no-cli-pager
  else
    echo "ℹ オプショングループ '$OPTION_GROUP_NAME' は既に存在します。スキップします。"
  fi

  echo "➕ オプション追加中..."
  aws rds add-option-to-option-group \
    --region "$REGION" \
    --option-group-name "$OPTION_GROUP_NAME" \
    --options file://"$OPTIONS_JSON_PATH" \
    --apply-immediately \
    --no-cli-pager

  echo "✅ 完了: $OPTION_GROUP_NAME"
done

