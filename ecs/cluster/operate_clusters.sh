#!/bin/bash

# スクリプトの利用方法を表示する関数
usage() {
    echo "使用方法: $0 <csv_file>"
    echo "  <csv_file>: クラスター定義を含むCSVファイルのパスを指定します。"
    exit 1
}

# 引数チェック
if [ -z "$1" ]; then
    echo "エラー: CSVファイルが指定されていません。"
    usage
fi

CSV_FILE="$1"

# CSVファイルが存在するかチェック
if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: CSVファイル '$CSV_FILE' が見つかりません。"
    exit 1
fi

echo "CSVファイル '$CSV_FILE' を処理中..."

# ヘッダーをスキップしてCSVファイルを読み込む
while IFS=',' read -r region action cluster_name tags_str; do
    # ヘッダー行をスキップ
    if [[ "$region" == "REGION" ]]; then
        continue
    fi

    # 必須フィールドの確認
    if [ -z "$region" ] || [ -z "$action" ] || [ -z "$cluster_name" ]; then
        echo "不正な形式の行をスキップします: REGION='$region', ACTION='$action', CLUSTERNAME='$cluster_name'"
        continue
    fi

    echo "--- クラスター '$cluster_name' ($region) の処理中 ---"
    echo "アクション: $action"

    # タグの処理
    TAG_PAIRS=()
    if [ -n "$tags_str" ]; then
        IFS=';' read -ra TAG_ITEMS <<< "$tags_str"
        for tag_item in "${TAG_ITEMS[@]}"; do
            if [[ -n "$tag_item" ]]; then
                KEY=$(echo "$tag_item" | cut -d'=' -f1)
                VALUE=$(echo "$tag_item" | cut -d'=' -f2-)
                
                if [ -n "$KEY" ] && [ -n "$VALUE" ]; then
                    TAG_PAIRS+=("key=$KEY,value=$VALUE")
                fi
            fi
        done
    fi

    case "$action" in
        add)
            echo "クラスター '$cluster_name' の作成を試行しています..."
            echo "タグ: ${TAG_PAIRS[*]}"
            
            # 基本コマンド
            BASE_COMMAND="aws ecs create-cluster --cluster-name \"$cluster_name\" \
                --capacity-providers FARGATE FARGATE_SPOT \
                --settings name=containerInsights,value=enabled \
                --region \"$region\" --no-cli-pager"
            
            # タグオプションを追加
            if [ ${#TAG_PAIRS[@]} -gt 0 ]; then
                TAGS_OPTION="--tags ${TAG_PAIRS[*]}"
                FULL_COMMAND="$BASE_COMMAND $TAGS_OPTION"
            else
                FULL_COMMAND="$BASE_COMMAND"
            fi
            
            echo "実行コマンド: $FULL_COMMAND"
            eval "$FULL_COMMAND"

            if [ $? -eq 0 ]; then
                echo "クラスター '$cluster_name' の作成が正常に開始されました。"
            else
                echo "エラー: クラスター '$cluster_name' の作成に失敗しました。"
            fi
            ;;
        remove)
            echo "クラスター '$cluster_name' の削除を試行しています..."
            DELETE_COMMAND="aws ecs delete-cluster --cluster \"$cluster_name\" --region \"$region\" --no-cli-pager"
            echo "実行コマンド: $DELETE_COMMAND"
            eval "$DELETE_COMMAND"
            
            if [ $? -eq 0 ]; then
                echo "クラスター '$cluster_name' の削除が正常に開始されました。"
            else
                echo "エラー: クラスター '$cluster_name' の削除に失敗しました。"
            fi
            ;;
        *)
            echo "警告: 不明なアクション '$action' です。クラスター '$cluster_name' の処理をスキップします。"
            ;;
    esac
    echo ""
done < <(tail -n +2 "$CSV_FILE")

echo "スクリプトの処理が完了しました。"
