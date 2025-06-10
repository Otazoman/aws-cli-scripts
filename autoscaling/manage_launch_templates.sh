#!/bin/bash

# ヘルパー関数: エラーメッセージを表示するが、スクリプトは終了しない
function error_log_and_continue {
  log_message "エラー: $1" >&2
}

# ヘルパー関数: ログメッセージを出力
function log_message {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# CSVファイルが引数で指定されているかチェック
if [ -z "$1" ]; then
  error_log_and_continue "使用方法: $0 <CSVファイルパス>"
  exit 1 # 使用方法エラーの場合はここで終了
fi

CSV_FILE="$1"

# CSVファイルの存在チェック
if [ ! -f "$CSV_FILE" ]; then
  error_log_and_continue "指定されたCSVファイル '$CSV_FILE' が見つかりません。"
  exit 1 # ファイルが見つからない場合はここで終了
fi

log_message "CSVファイル '$CSV_FILE' を読み込み中..."

# ヘッダー行をスキップしてCSVを処理
# CSV形式: ACTION,REGION,TEMPLATE_NAME,IMAGEID,INSTANCE_TYPE,VERSION_DESCRIPTION,TARGET_VERSION
(tail -n +2 "$CSV_FILE" || error_log_and_continue "CSVファイルの読み込みに失敗しました。この後の処理は行われません。" && exit 1) | while IFS=',' read -r ACTION REGION TEMPLATE_NAME IMAGEID INSTANCE_TYPE VERSION_DESCRIPTION TARGET_VERSION; do
  # パラメータのトリムと正規化
  ACTION=$(echo "$ACTION" | xargs | tr '[:lower:]' '[:upper:]') # 小文字を大文字に変換
  REGION=$(echo "$REGION" | xargs)
  TEMPLATE_NAME=$(echo "$TEMPLATE_NAME" | xargs)
  IMAGEID=$(echo "$IMAGEID" | xargs)
  INSTANCE_TYPE=$(echo "$INSTANCE_TYPE" | xargs)
  VERSION_DESCRIPTION=$(echo "$VERSION_DESCRIPTION" | xargs)
  TARGET_VERSION=$(echo "$TARGET_VERSION" | xargs)

  if [ -z "$ACTION" ] || [ -z "$REGION" ] || [ -z "$TEMPLATE_NAME" ]; then
    log_message "警告: 必須パラメータ (ACTION, REGION, TEMPLATE_NAME) が不足している行をスキップします。"
    continue
  fi

  log_message "--- 処理対象: アクション '$ACTION', テンプレート名 '$TEMPLATE_NAME' (リージョン: $REGION) ---"

  # 起動テンプレートの存在確認
  LAUNCH_TEMPLATE_EXISTS=0
  if aws ec2 describe-launch-templates --region "$REGION" --launch-template-names "$TEMPLATE_NAME" &>/dev/null; then
    if [ $(aws ec2 describe-launch-templates --region "$REGION" --launch-template-names "$TEMPLATE_NAME" | jq -r '.LaunchTemplates | length') -gt 0 ]; then
      LAUNCH_TEMPLATE_EXISTS=1
    fi
  fi

  case "$ACTION" in
    "ADD")
      if [ "$LAUNCH_TEMPLATE_EXISTS" -eq 0 ]; then
        log_message "起動テンプレート '$TEMPLATE_NAME' が存在しません。新規作成します。"
        # VERSION_DESCRIPTIONが指定されていなければ自動生成
        if [ -z "$VERSION_DESCRIPTION" ]; then
          VERSION_DESCRIPTION="initial-creation-$(date +%Y%m%d-%H%M%S)"
        fi

        aws ec2 create-launch-template \
          --region "${REGION}" \
          --launch-template-name "${TEMPLATE_NAME}" \
          --version-description "${VERSION_DESCRIPTION}" \
          --launch-template-data "{\"ImageId\":\"${IMAGEID}\",\"InstanceType\":\"${INSTANCE_TYPE}\"}"
        if [ $? -ne 0 ]; then
            error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' の作成に失敗しました。次の行へ進みます。"
            continue
        fi
        log_message "起動テンプレート '$TEMPLATE_NAME' が正常に作成されました。(バージョン1がデフォルトに設定されます)"

        # 新規作成時はバージョン1がデフォルトになるため、TARGET_VERSIONによる明示的なデフォルト設定は不要
        # ただし、もしTARGET_VERSIONが指定されており、それが1以外の場合はここで警告を出すことも可能
        if [ -n "$TARGET_VERSION" ] && [ "$TARGET_VERSION" != "1" ]; then
            log_message "警告: 新規作成時ですが、TARGET_VERSION '$TARGET_VERSION' が指定されました。バージョン1がデフォルトとして作成されます。デフォルトを更新する場合は、別途UPDATE処理として実行してください。"
        fi

      else
        log_message "起動テンプレート '$TEMPLATE_NAME' は既に存在します。バージョンの更新を確認します。"

        # 現在のデフォルトバージョン情報を取得
        CURRENT_DEFAULT_VERSION_DATA=$(aws ec2 describe-launch-template-versions \
          --region "$REGION" \
          --launch-template-name "$TEMPLATE_NAME" \
          --query "LaunchTemplateVersions[?DefaultVersion==\`true\`].[ImageId,InstanceType,VersionNumber]" \
          --output text)
        if [ $? -ne 0 ]; then
            error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' のデフォルトバージョン情報取得に失敗しました。次の行へ進みます。"
            continue
        fi

        CURRENT_IMAGE_ID=$(echo "$CURRENT_DEFAULT_VERSION_DATA" | awk '{print $1}')
        CURRENT_INSTANCE_TYPE=$(echo "$CURRENT_DEFAULT_VERSION_DATA" | awk '{print $2}')
        CURRENT_VERSION_NUMBER=$(echo "$CURRENT_DEFAULT_VERSION_DATA" | awk '{print $3}')

        SHOULD_CREATE_NEW_VERSION=false
        # AWS APIの応答が空の場合、CURRENT_*変数が空になる可能性があるためチェック
        if [ -z "$CURRENT_VERSION_NUMBER" ]; then
            log_message "警告: 起動テンプレート '$TEMPLATE_NAME' のデフォルトバージョン情報が見つかりませんでした。新しいバージョンを作成します。"
            SHOULD_CREATE_NEW_VERSION=true
        elif [ "$CURRENT_IMAGE_ID" != "$IMAGEID" ] || [ "$CURRENT_INSTANCE_TYPE" != "$INSTANCE_TYPE" ]; then
            SHOULD_CREATE_NEW_VERSION=true
        fi


        log_message "現在のデフォルトバージョン (${CURRENT_VERSION_NUMBER}): ImageId=$CURRENT_IMAGE_ID, InstanceType=$CURRENT_INSTANCE_TYPE"
        log_message "CSV指定: ImageId=$IMAGEID, InstanceType=$INSTANCE_TYPE, TARGET_VERSION=$TARGET_VERSION"

        # TARGET_VERSIONが指定されている場合、そのバージョンをデフォルトに設定
        if [ -n "$TARGET_VERSION" ]; then
          log_message "TARGET_VERSION '$TARGET_VERSION' が指定されています。このバージョンをデフォルトに設定します。"
          aws ec2 modify-launch-template \
            --region "$REGION" \
            --launch-template-name "$TEMPLATE_NAME" \
            --default-version "$TARGET_VERSION"
          if [ $? -ne 0 ]; then
              error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' のデフォルトバージョン ($TARGET_VERSION) 更新に失敗しました。次の行へ進みます。"
              continue
          fi
          log_message "デフォルトバージョンを $TARGET_VERSION に更新しました。"
        elif [ "$SHOULD_CREATE_NEW_VERSION" = true ]; then
          # 内容に変更がある場合のみ新バージョンを作成
          log_message "起動テンプレート '$TEMPLATE_NAME' に新しいバージョンを作成します。"
          if [ -z "$VERSION_DESCRIPTION" ]; then
            VERSION_DESCRIPTION="updated-from-csv-$(date +%Y%m%d-%H%M%S)"
          fi

          # ベースとなるバージョン（現在のデフォルトバージョン）を取得
          BASE_VERSION=$(aws ec2 describe-launch-template-versions \
            --region "$REGION" \
            --launch-template-name "$TEMPLATE_NAME" \
            --query "LaunchTemplateVersions[?DefaultVersion==\`true\`].VersionNumber | [0]" \
            --output text)
          if [ $? -ne 0 ]; then
              error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' のデフォルトバージョン取得に失敗しました。新バージョン作成をスキップします。次の行へ進みます。"
              continue
          fi

          if [ -z "$BASE_VERSION" ]; then
            error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' のデフォルトバージョンが見つかりませんでした。新バージョン作成をスキップします。次の行へ進みます。"
            continue
          fi

          log_message "ベースバージョン: $BASE_VERSION"

          aws ec2 create-launch-template-version \
            --region "$REGION" \
            --launch-template-name "$TEMPLATE_NAME" \
            --source-version "$BASE_VERSION" \
            --version-description "${VERSION_DESCRIPTION}" \
            --launch-template-data "{\"ImageId\":\"${IMAGEID}\",\"InstanceType\":\"${INSTANCE_TYPE}\"}"
          if [ $? -ne 0 ]; then
              error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' の新バージョン作成に失敗しました。次の行へ進みます。"
              continue
          fi

          # 最新バージョンをデフォルトに設定
          LATEST_VERSION=$(aws ec2 describe-launch-template-versions \
            --region "$REGION" \
            --launch-template-name "$TEMPLATE_NAME" \
            --query "max_by(LaunchTemplateVersions, &VersionNumber).VersionNumber" \
            --output text)
          if [ $? -ne 0 ]; then
              error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' の最新バージョン取得に失敗しました。次の行へ進みます。"
              continue
          fi

          if [ -z "$LATEST_VERSION" ]; then
            error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' の最新バージョンが見つかりませんでした。デフォルト更新をスキップします。次の行へ進みます。"
            continue
          fi

          log_message "最新バージョン: $LATEST_VERSION をデフォルトに設定します。"
          aws ec2 modify-launch-template \
            --region "$REGION" \
            --launch-template-name "$TEMPLATE_NAME" \
            --default-version "$LATEST_VERSION"
          if [ $? -ne 0 ]; then
              error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' のデフォルトバージョン ($LATEST_VERSION) 更新に失敗しました。次の行へ進みます。"
              continue
          fi
          log_message "デフォルトバージョンを $LATEST_VERSION に更新しました。"
        else
          # TARGET_VERSIONも指定されておらず、かつ内容に変更がない場合
          log_message "情報: 起動テンプレート '$TEMPLATE_NAME' の内容に変更はなく、TARGET_VERSIONも指定されていません。スキップします。"
        fi
      fi
      ;;

    "REMOVE")
      if [ "$LAUNCH_TEMPLATE_EXISTS" -eq 0 ]; then
        log_message "情報: 起動テンプレート '$TEMPLATE_NAME' は存在しません。削除アクションですがスキップします。"
      else
        log_message "起動テンプレート '$TEMPLATE_NAME' を削除します。"
        TEMPLATE_ID=$(aws ec2 describe-launch-templates \
          --region "$REGION" \
          --launch-template-names "$TEMPLATE_NAME" \
          --query "LaunchTemplates[].LaunchTemplateId" \
          --output text 2>/dev/null) # 2>/dev/null は jq でパースする前の段階のエラーメッセージを抑制

        if [ -z "$TEMPLATE_ID" ]; then
          error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' のIDが見つかりませんでした。削除できません。次の行へ進みます。"
          continue
        fi

        aws ec2 delete-launch-template \
          --launch-template-id "$TEMPLATE_ID" \
          --region "$REGION"
        if [ $? -ne 0 ]; then
            error_log_and_continue "起動テンプレート '$TEMPLATE_NAME' の削除に失敗しました。次の行へ進みます。"
            continue
        fi
        log_message "起動テンプレート '$TEMPLATE_NAME' が正常に削除されました。"
      fi
      ;;

    *)
      log_message "警告: 不明なアクション '$ACTION' です。この行をスキップします。"
      ;;
  esac
  echo # 各テンプレート処理後に空行を追加して見やすくする
done

log_message "すべての処理が完了しました。"
