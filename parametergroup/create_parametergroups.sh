#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "使用方法: $0 <config_file.csv>"
    echo "  <config_file.csv>: パラメータグループを定義したCSVファイル（必須）"
    exit 1
}

# 引数チェック
if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

CONFIG_FILE="$1"

# 指定されたCSVファイルの存在確認
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "エラー: 指定された設定ファイルが見つかりません: $CONFIG_FILE" >&2
    usage
fi

# メイン処理関数
process_parameter_groups() {
    # CSVファイルを1行ずつ読み込む（空行も無視）
    while IFS=, read -r region name type family description params_file || [ -n "$region" ]; do
        # ヘッダーまたは空行をスキップ
        if [[ "$(echo "$region" | tr -d '\xef\xbb\xbf')" == "REGION" || -z "$(echo "$region" | tr -d '\xef\xbb\xbf')" ]]; then
            continue
        fi

        # 各フィールドの前後空白・制御文字を削除
        region=$(echo "$region" | sed 's/^\xef\xbb\xbf//' | tr -d '[:space:]') # BOMも削除
        name=$(echo "$name" | tr -d '[:space:]')
        type=$(echo "$type" | tr -d '[:space:]')
        family=$(echo "$family" | tr -d '[:space:]')
        description=$(echo "$description" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        params_file=$(echo "$params_file" | tr -d '[:space:]')
        params_file_path="$SCRIPT_DIR/$params_file"


        # region, name, family, description のいずれかが未指定ならスキップ
        if [[ -z "$region" || -z "$name" || -z "$family" || -z "$description" ]]; then
            echo "エラー: 必須フィールド(region, name, family, description)が不足しています。この行はスキップします。" >&2
            echo "行の内容: region='$region', name='$name', type='$type', family='$family', description='$description', params_file='$params_file'" >&2
            continue
        fi

        echo "========================================"
        echo "処理中: $name ($type) in $region"
        echo "========================================"

        AWS_CLI_ARGS="--region $region"

        # ElastiCache の処理
        if [[ "$type" == "elasticache" ]]; then
            # パラメータグループの存在確認
            if aws elasticache describe-cache-parameter-groups --cache-parameter-group-name "$name" $AWS_CLI_ARGS >/dev/null 2>&1; then
                echo "パラメータグループ $name は既に存在します。"
                # 既に存在する場合でもパラメータ適用は行う可能性があるため、スキップしない
            else
                 echo "ElastiCacheパラメータグループを作成中: $name"
                 if ! aws elasticache create-cache-parameter-group \
                     --cache-parameter-group-name "$name" \
                     --cache-parameter-group-family "$family" \
                     --description "$description" \
                     $AWS_CLI_ARGS; then
                     echo "エラー: ElastiCacheパラメータグループ $name の作成に失敗しました。このパラメータグループの処理をスキップします。" >&2
                     continue # 作成失敗したらパラメータ適用もスキップ
                 fi
            fi

            # パラメータファイルの適用
            if [[ -n "$params_file_path" && -f "$params_file_path" ]]; then
                echo "パラメータファイル '$params_file_path' を適用します。"
                # パラメータファイルのヘッダー行をスキップ (最初の1行を読み飛ばす)
                read -r < "$params_file_path" || true # ファイルが空の場合のエラーを防ぐ
                tail -n +2 "$params_file_path" | while IFS=, read -r param_name value; do
                    # 空行またはコメント行をスキップ
                    [[ -z "$param_name" || "$param_name" =~ ^[[:space:]]*# ]] && continue # 行頭のコメントも考慮
                    param_name=$(echo "$param_name" | tr -d '[:space:]')
                    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                    # パラメータ名が空の場合はスキップ（カンマ区切りで値だけある行など）
                    [[ -z "$param_name" ]] && continue

                    echo "パラメータを適用中 [elasticache]: $param_name = '$value'"
                    # エラーが発生しても後続のパラメータ処理を続行するため、&& or || を使用しない
                    aws elasticache modify-cache-parameter-group \
                        --cache-parameter-group-name "$name" \
                        --parameter-name-values "ParameterName=$param_name,ParameterValue=$value" \
                        $AWS_CLI_ARGS \
                        --no-cli-pager || { echo "警告: パラメータ $param_name の適用に失敗しました。" >&2; }

                done
            elif [[ -n "$params_file" ]]; then
                echo "警告: パラメータファイル '$params_file_path' が見つかりません。パラメータの適用はスキップします。" >&2
            else
                echo "パラメータファイルが指定されていません。パラメータの適用はスキップします。"
            fi

        # RDS クラスターパラメータグループ
        elif [[ "$type" == "rds-cluster" ]]; then
            # パラメータグループの存在確認
            if aws rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$name" $AWS_CLI_ARGS >/dev/null 2>&1; then
                echo "クラスタパラメータグループ $name は既に存在します。"
            else
                echo "クラスタパラメータグループを作成中: $name"
                if ! aws rds create-db-cluster-parameter-group \
                    --db-cluster-parameter-group-name "$name" \
                    --db-parameter-group-family "$family" \
                    --description "$description" \
                    $AWS_CLI_ARGS; then
                    echo "エラー: RDSクラスタパラメータグループ $name の作成に失敗しました。このパラメータグループの処理をスキップします。" >&2
                    continue # 作成失敗したらパラメータ適用もスキップ
                fi
            fi

            if [[ -n "$params_file_path" && -f "$params_file_path" ]]; then
                 echo "パラメータファイル '$params_file_path' を適用します。"
                read -r < "$params_file_path" || true # ファイルが空の場合のエラーを防ぐ
                tail -n +2 "$params_file_path" | while IFS=, read -r param_name value apply_method; do 
                    # 空行またはコメント行をスキップ
                    [[ -z "$param_name" || "$param_name" =~ ^[[:space:]]*# ]] && continue # 行頭のコメントも考慮
                    param_name=$(echo "$param_name" | tr -d '[:space:]')
                    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    apply_method=$(echo "$apply_method" | tr -d '[:space:]')

                     # パラメータ名が空の場合はスキップ（カンマ区切りで値だけある行など）
                    [[ -z "$param_name" ]] && continue

                    # apply_methodが指定されていない場合はデフォルト値を使用（immediateを想定）
                    if [[ -z "$apply_method" ]]; then
                        apply_method="immediate"
                         echo "警告: パラメータ $param_name の ApplyMethod が指定されていません。'immediate' を使用します。RDSのファミリーによっては異なる場合があります。" >&2
                    fi

                    echo "パラメータを適用中 [cluster]: $param_name = '$value' ($apply_method)"
                    aws rds modify-db-cluster-parameter-group \
                        --db-cluster-parameter-group-name "$name" \
                        --parameters "ParameterName=$param_name,ParameterValue=$value,ApplyMethod=$apply_method" \
                        $AWS_CLI_ARGS \
                        --no-cli-pager || { echo "警告: パラメータ $param_name の適用に失敗しました。" >&2; }

                done
            elif [[ -n "$params_file" ]]; then
                echo "警告: パラメータファイル '$params_file_path' が見つかりません。パラメータの適用はスキップします。" >&2
            else
                echo "パラメータファイルが指定されていません。パラメータの適用はスキップします。"
            fi

        # RDS インスタンスパラメータグループ
        elif [[ "$type" == "rds-instance" ]]; then
             # パラメータグループの存在確認
            if aws rds describe-db-parameter-groups --db-parameter-group-name "$name" $AWS_CLI_ARGS >/dev/null 2>&1; then
                echo "インスタンスパラメータグループ $name は既に存在します。"
            else
                echo "インスタンスパラメータグループを作成中: $name"
                if ! aws rds create-db-parameter-group \
                    --db-parameter-group-name "$name" \
                    --db-parameter-group-family "$family" \
                    --description "$description" \
                    $AWS_CLI_ARGS; then
                    echo "エラー: RDSインスタンスパラメータグループ $name の作成に失敗しました。このパラメータグループの処理をスキップします。" >&2
                    continue # 作成失敗したらパラメータ適用もスキップ
                fi
            fi

            if [[ -n "$params_file_path" && -f "$params_file_path" ]]; then
                 echo "パラメータファイル '$params_file_path' を適用します。"
                read -r < "$params_file_path" || true # ファイルが空の場合のエラーを防ぐ
                tail -n +2 "$params_file_path" | while IFS=, read -r param_name value apply_method; do
                     # 空行またはコメント行をスキップ
                    [[ -z "$param_name" || "$param_name" =~ ^[[:space:]]*# ]] && continue # 行頭のコメントも考慮
                    param_name=$(echo "$param_name" | tr -d '[:space:]')
                    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    apply_method=$(echo "$apply_method" | tr -d '[:space:]')

                    # パラメータ名が空の場合はスキップ（カンマ区切りで値だけある行など）
                    [[ -z "$param_name" ]] && continue

                     # apply_methodが指定されていない場合はデフォルト値を使用（immediateを想定）
                    if [[ -z "$apply_method" ]]; then
                        apply_method="immediate" # または pending-reboot など、ファミリーによる
                         echo "警告: パラメータ $param_name の ApplyMethod が指定されていません。'immediate' を使用します。RDSのファミリーによっては異なる場合があります。" >&2
                    fi

                    echo "パラメータを適用中 [instance]: $param_name = '$value' ($apply_method)"
                    aws rds modify-db-parameter-group \
                        --db-parameter-group-name "$name" \
                        --parameters "ParameterName=$param_name,ParameterValue=$value,ApplyMethod=$apply_method" \
                        $AWS_CLI_ARGS \
                        --no-cli-pager || { echo "警告: パラメータ $param_name の適用に失敗しました。" >&2; }

                done
            elif [[ -n "$params_file" ]]; then
                echo "警告: パラメータファイル '$params_file_path' が見つかりません。パラメータの適用はスキップします。" >&2
            else
                echo "パラメータファイルが指定されていません。パラメータの適用はスキップします。"
            fi

        else
            echo "不明なタイプ: $type。このパラメータグループの処理をスキップします。" >&2
            continue
        fi

        echo "完了: $name"
        echo "----------------------------------------"
    done < "$CONFIG_FILE"

}

process_parameter_groups

echo "全てのパラメータグループの処理が完了しました。"
