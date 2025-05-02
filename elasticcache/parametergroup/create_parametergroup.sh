#!/bin/bash

SCRIPT_DIR=$(dirname "$0")

# Show usage in English
usage() {
    echo "Usage: $0 <config_file.csv>"
    echo "  <config_file.csv>: CSV file defining parameter groups (required)"
    exit 1
}

# Check arguments
if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

CONFIG_FILE="$1"

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    usage
fi

# Main processing function (messages in Japanese)
process_parameter_groups() {
    # Process CSV file (ignore empty lines)
    while IFS=, read -r region name parameter_family description params_file || [ -n "$region" ]; do
        # Skip header and empty lines
        if [[ "$region" == "REGION" || -z "$region" ]]; then
            continue
        fi

        # Trim whitespace
        region=$(echo "$region" | tr -d '\r' | xargs)
        params_file=$(echo "$params_file" | tr -d '\r' | xargs)
        
        echo "========================================"
        echo "処理中: $name in $region"
        echo "========================================"

        # Set region for each command
        AWS_CLI_ARGS="--region $region"
        
        # Check if parameter group exists
        if aws elasticache describe-cache-parameter-groups --cache-parameter-group-name "$name" $AWS_CLI_ARGS >/dev/null 2>&1; then
            echo "パラメータグループ $name は既に存在します。作成をスキップします。"
        else
            echo "パラメータグループを作成中: $name"
            aws elasticache create-cache-parameter-group \
                --cache-parameter-group-name "$name" \
                --cache-parameter-group-family "$parameter_family" \
                --description "$description" \
                $AWS_CLI_ARGS
        fi

        # Only apply parameters if PARAMS_FILE is specified
        if [[ -n "$params_file" ]]; then
            echo "パラメータファイル: $params_file"
            
            # Get full path to parameter file (relative to config file location)
            PARAMS_FILE=$(realpath -m "$(dirname "$CONFIG_FILE")/${params_file}")
            if [[ ! -f "$PARAMS_FILE" ]]; then
                # Also check script directory
                PARAMS_FILE=$(realpath -m "${SCRIPT_DIR}/${params_file}")
                if [[ ! -f "$PARAMS_FILE" ]]; then
                    echo "エラー: パラメータファイルが見つかりません: $params_file (検索場所: $(dirname "$CONFIG_FILE")/${params_file} と ${SCRIPT_DIR}/${params_file})" >&2
                    continue
                fi
            fi

            # Apply parameters from CSV file
            while IFS=, read -r param_name value || [ -n "$param_name" ]; do
                # Skip header and empty lines
                if [[ "$param_name" == "PARAM_NAME" || -z "$param_name" ]]; then
                    continue
                fi

                # Trim whitespace
                param_name=$(echo "$param_name" | xargs)
                value=$(echo "$value" | xargs)

                echo "パラメータを適用中: $param_name = $value"
                aws elasticache modify-cache-parameter-group \
                    --cache-parameter-group-name "$name" \
                    --parameter-name-values "ParameterName=$param_name,ParameterValue=$value" \
                    $AWS_CLI_ARGS \
                    --no-cli-pager
            done < "$PARAMS_FILE"
        else
            echo "パラメータファイルが指定されていません。パラメータ変更をスキップします。"
        fi

        echo "完了: $name"
        echo "----------------------------------------"
    done < <(tail -n +2 "$CONFIG_FILE")  # Skip header line
}

# Execute main processing
process_parameter_groups

echo "全てのパラメータグループの処理が完了しました。"
