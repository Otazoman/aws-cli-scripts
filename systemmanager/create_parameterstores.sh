#!/bin/bash

# スクリプト名
SCRIPT_NAME=$(basename "$0")

# ヘルプメッセージを表示する関数
show_help() {
  echo "使い方: $SCRIPT_NAME <parameter_file.csv>"
}

# コマンドライン引数の確認
if [ $# -eq 0 ]; then
  echo "エラー: 入力CSVファイルのパスが必要です。" >&2
  show_help
  exit 1
fi

PARAM_FILE="$1"

# ファイルの存在チェック
if [ ! -f "$PARAM_FILE" ]; then
  echo "エラー: ファイルが見つかりません: $PARAM_FILE" >&2
  exit 1
fi

# AWS CLIがインストールされているかチェック (簡易)
if ! command -v aws &> /dev/null
then
    echo "エラー: aws CLI が見つかりません。インストールしてください。" >&2
    exit 1
fi

echo "パラメータを読み込んでいます: $PARAM_FILE"

# ファイルディスクリプタ3を開く
exec 3< "$PARAM_FILE"

# ヘッダ行を読み飛ばす (ファイルディスクリプタ3から読み込む)
read -r <&3

# ファイルディスクリプタ3から残りの行を読み込んでループ処理
# IFS=',' でカンマ区切りを指定
# -r でバックスラッシュによるエスケープを無効化
# name, value, type, tags の4カラムを読み込む
while IFS=',' read -r name value type tags <&3; do

  # 行の先頭や空白行、Nameが空の行をスキップ
  if [[ -z "$name" || "$name" =~ ^# ]]; then
    continue
  fi

  # 不要な空白をトリム (任意だが推奨)
  name=$(echo "$name" | xargs)
  # valueはStringListの場合に変換するのでここではトリムしない（末尾の空白などが含まれる可能性考慮）
  processed_type=$(echo "$type" | xargs | tr '[:upper:]' '[:lower:]') # タイプを小文字に変換して比較しやすくする
  # tagsはセミコロンで分割する前にトリム
  tags=$(echo "$tags" | xargs)


  echo "----------------------------------------"
  echo "パラメータを処理中: $name"
  echo "  タイプ: $processed_type" # Use processed type for logging
  echo "  元タグ文字列: '$tags'" # デバッグ用に元のタグ文字列を表示
  # SecureStringの場合は値の表示を控えるなど配慮が必要であればここで調整
  # echo "  値: '$value'" # 元のvalueを表示する場合はこちら

  # --- 1. Put/Update Parameter (Value and Type) ---
  # AWS CLIの制限により、put-parameter --overwrite と --tags は併用できないため、タグはここでは付けない
  PUT_PARAM_ARGS=(
    aws ssm put-parameter
    --overwrite # 値とタイプを上書きするために使用
    --name "$name"
  )

  local_value_to_use="$value" # Variable to hold the value ready for --value argument

  # タイプに応じたオプションを追加し、StringListの場合は値を変換
  case "$processed_type" in
    "string"|"text"|"ec2image")
      PUT_PARAM_ARGS+=(--type "String")
      # Stringの場合はvalueをそのまま使用 (必要ならここでトリム)
      local_value_to_use=$(echo "$value" | xargs)
      ;;
    "stringlist")
      PUT_PARAM_ARGS+=(--type "StringList")
      # StringListの場合、valueのセミコロン(;)をカンマ(,)に変換
      local_value_to_use=$(echo "$value" | tr ';' ',')
      # Valueが空文字列になるケースも考慮し、空の場合は処理しないなど必要なら追加
      ;;
    "securestring")
      PUT_PARAM_ARGS+=(--type "SecureString")
      PUT_PARAM_ARGS+=(--key-id "alias/aws/ssm") # デフォルトのKMSキーID
      # SecureStringの場合はvalueをそのまま使用 (必要ならここでトリム)
      local_value_to_use=$(echo "$value" | xargs)
      ;;
    *)
      # このケースは通常到達しないが、安全のため
      echo "内部エラー: put-parameter 引数に対する未処理のタイプ '${processed_type}' です。スキップします。" >&2
      continue
      ;;
  esac

  # 加工済みのvalue引数を追加
  PUT_PARAM_ARGS+=(--value "$local_value_to_use")

  # 実行コマンドを表示 (デバッグ用)
  echo "put-parameter を実行: ${PUT_PARAM_ARGS[@]}"

  # aws ssm put-parameter コマンドを実行
  "${PUT_PARAM_ARGS[@]}"
  PUT_STATUS=$?

  if [ $PUT_STATUS -ne 0 ]; then
    echo "エラー: パラメータ '${name}' の値/タイプの登録または更新に失敗しました。" >&2
    # エラー発生時にスクリプトを停止したい場合は exit 1 を追加
    # exit 1
    continue # putが失敗した場合はタグ更新もスキップし、次のパラメータへ
  else
    echo "パラメータ '${name}' の値/タイプを正常に登録/更新しました。"
  fi

  # --- 2. Add/Update Tags (if applicable) ---
  # タグはStringとSecureStringタイプのみに付与可能
  if [ -n "$tags" ]; then
    case "$processed_type" in
      "string"|"securestring")
        # add-tags-to-resource コマンドの引数配列を初期化
        ADD_TAGS_ARGS=(
          aws ssm add-tags-to-resource
          --resource-type Parameter
          --resource-id "$name"
          --tags # ここで --tags オプション自体を追加
        )

        # セミコロンで区切られたタグの文字列を個別の Key=Value ペアに分割
        # -a オプションで配列に読み込む
        # IFSを一時的に変更して読み込む
        IFS=';' # IFSをローカルに変更
        read -r -a tag_pairs <<< "$tags"
        IFS=${IFS} # IFSを元に戻す

        # 分割された各 Key=Value ペアを処理し、整形してADD_TAGS_ARGSに追加
        for tag_pair in "${tag_pairs[@]}"; do
          # 個別のタグペアから前後の空白をトリム
          trimmed_tag_pair=$(echo "$tag_pair" | xargs)

          # トリミング後に空になったペアはスキップ (例:末尾に余分な;があった場合)
          if [ -z "$trimmed_tag_pair" ]; then
            continue
          fi

          # KeyとValueに分割 (最初の=で分割。Valueに=が含まれてもOK)
          tag_key="${trimmed_tag_pair%%=*}" # 最初の=より前の部分
          tag_value="${trimmed_tag_pair#*=}" # 最初の=より後ろの部分

          # add-tags-to-resource --tags が期待する "Key=key,Value=value" 形式に整形
          # この整形された文字列をADD_TAGS_ARGS配列に新しい要素として追加する
          FORMATTED_TAG_ARG="Key=${tag_key},Value=${tag_value}"

          # 整形したタグ文字列を ADD_TAGS_ARGS 配列に新しい要素として追加
          ADD_TAGS_ARGS+=("$FORMATTED_TAG_ARG")
        done

        # タグが一つも有効でなかった場合 (例: tags="", または ";;;") は add-tags-to-resource を実行しない
        # --tags オプション自体は追加済みなので、タグペアの引数がなければ実行しない
        # ADD_TAGS_ARGSの要素数が最低4つ (--resource-type, --resource-id, --tags + 1つ以上のタグペア) 必要
        if [ ${#ADD_TAGS_ARGS[@]} -gt 4 ]; then
            # 実行コマンドを表示 (デバッグ用)
            echo "add-tags-to-resource を実行: ${ADD_TAGS_ARGS[@]}"

            # aws ssm add-tags-to-resource コマンドを実行
            "${ADD_TAGS_ARGS[@]}"
            ADD_TAGS_STATUS=$?

            if [ $ADD_TAGS_STATUS -ne 0 ]; then
              echo "エラー: パラメータ '${name}' のタグの追加または更新に失敗しました。" >&2
              # タグ更新エラーは致命的でない場合が多いので、ここでは継続
            else
              echo "パラメータ '${name}' のタグを正常に追加/更新しました。"
            fi
        else
            echo "情報: パラメータ '${name}' の処理後に有効なタグが見つかりませんでした。add-tags-to-resource をスキップします。"
        fi
        ;;
      "stringlist")
        echo "情報: パラメータ '${name}' は StringList タイプであり、タグをサポートしていません。タグの割り当てをスキップします。"
        ;;
      *)
        # このケースは通常到達しないが、安全のため
        echo "内部エラー: タグ処理に対する未処理のタイプ '${processed_type}' です。タグの割り当てをスキップします。" >&2
        ;;
    esac
  else
    echo "情報: CSVにパラメータ '${name}' のタグが指定されていません。タグの割り当てをスキップします。"
  fi


done <&3 # ファイルディスクリプタ3から読み込み続ける

# ファイルディスクリプタを閉じる
exec 3<&-

echo "----------------------------------------"
echo "スクリプトは ${PARAM_FILE} の処理を完了しました。"
echo "----------------------------------------"

exit 0
