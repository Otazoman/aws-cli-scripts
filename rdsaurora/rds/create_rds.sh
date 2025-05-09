#!/bin/bash

# スクリプト名
SCRIPT_NAME=$(basename "$0")

# ログ出力関数
log() {
    # スクリプト名をログメッセージに追加
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] $1"
}

# エラーメッセージを出力して終了する関数
error_exit() {
    log "エラー: $1"
    exit 1
}

# セキュリティグループ名またはIDからセキュリティグループIDを取得する関数
get_security_group_id() {
    local sg_name_or_id="$1"
    local region="$2"
    local sg_id=""

    # 空白を除去
    sg_name_or_id=$(echo "$sg_name_or_id" | xargs)

    if [[ "$sg_name_or_id" == sg-* ]]; then
        # ID形式の場合はそのまま返す
        sg_id="$sg_name_or_id"
    else
        # 名前形式の場合はIDを検索
        sg_id=$(aws ec2 describe-security-groups \
            --region "$region" \
            --filters "Name=group-name,Values=$sg_name_or_id" \
            --query 'SecurityGroups[0].GroupId' \
            --output text \
            --no-cli-pager 2>/dev/null)

        if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
            log "エラー: セキュリティグループ '$sg_name_or_id' (リージョン $region) が見つかりません。"
            return 1
        fi
    fi

    echo "$sg_id"
    return 0
}

# インスタンスの存在をチェックする関数
check_instance_exists() {
    local instance_id="$1"
    local region="$2"
    local status=""

    status=$(aws rds describe-db-instances \
        --region "$region" \
        --db-instance-identifier "$instance_id" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text \
        --no-cli-pager 2>/dev/null)

    if [ -z "$status" ] || [ "$status" = "None" ]; then
        echo ""
    else
        echo "$status"
    fi
}

# RDSインスタンスを更新する関数
update_rds_instance() {
    log "${DB_IDENTIFIER} のパラメータ更新を開始 (リージョン: ${REGION})"

    # セキュリティグループ名からIDへの変換とリスト作成
    SECURITY_GROUP_IDS=()
    if [ -n "$VPC_SG_IDS" ]; then
        IFS=';' read -ra SG_NAMES_OR_IDS_ARRAY <<< "$VPC_SG_IDS"
        for sg in "${SG_NAMES_OR_IDS_ARRAY[@]}"; do
            if [ -z "$(echo "$sg" | xargs)" ]; then continue; fi

            sg_id=$(get_security_group_id "$(echo "$sg" | xargs)" "$REGION")
            if [ "$?" -ne 0 ]; then
                log "セキュリティグループIDの取得に失敗したため、インスタンス更新を中止します。"
                return 1
            fi
            SECURITY_GROUP_IDS+=("$sg_id")
        done
    fi

    local CMD=("aws" "rds" "modify-db-instance" \
        "--region" "$REGION" \
        "--db-instance-identifier" "$DB_IDENTIFIER" \
        "--apply-immediately" \
        "--no-cli-pager")

    local params_added=0

    # 更新可能なパラメータを追加
    if [ -n "$BACKUP_RETENTION" ]; then CMD+=("--backup-retention-period" "$BACKUP_RETENTION"); params_added=1; fi
    if [ -n "$BACKUP_WINDOW" ]; then CMD+=("--preferred-backup-window" "$BACKUP_WINDOW"); params_added=1; fi
    if [ -n "$MAINTENANCE_WINDOW" ]; then CMD+=("--preferred-maintenance-window" "$MAINTENANCE_WINDOW"); params_added=1; fi
    if [ -n "$PARAM_GROUP" ]; then CMD+=("--db-parameter-group-name" "$PARAM_GROUP"); params_added=1; fi
    if [ -n "$OPT_GROUP" ]; then CMD+=("--option-group-name" "$OPT_GROUP"); params_added=1; fi
    if [ -n "$INSTANCE_CLASS" ]; then CMD+=("--db-instance-class" "$INSTANCE_CLASS"); params_added=1; fi
    if [ -n "$STORAGE_TYPE" ]; then CMD+=("--storage-type" "$STORAGE_TYPE"); params_added=1; fi
    if [ -n "$ALLOCATED_STORAGE" ]; then CMD+=("--allocated-storage" "$ALLOCATED_STORAGE"); params_added=1; fi
    if [ -n "$MAX_ALLOCATED_STORAGE" ]; then CMD+=("--max-allocated-storage" "$MAX_ALLOCATED_STORAGE"); params_added=1; fi

    # Security Group IDリストを結合して追加
    if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
        CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        params_added=1
    fi

    # Publicly Accessible
    if [ -n "$PUBLIC_ACCESS" ]; then
        if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--publicly-accessible"); params_added=1; fi
        if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-publicly-accessible"); params_added=1; fi
    fi

    # Multi-AZ
    if [ -n "$MULTI_AZ" ]; then
        if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--multi-az"); params_added=1; fi
        if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-multi-az"); params_added=1; fi
    fi

    # Performance Insights
    if [ -n "$ENABLE_PERFORMANCE_INSIGHTS" ]; then
        if [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
            CMD+=("--enable-performance-insights")
            params_added=1
            if [ -n "$PERFORMANCE_RETENTION" ]; then
                CMD+=("--performance-insights-retention-period" "$PERFORMANCE_RETENTION")
            fi
        elif [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then
            CMD+=("--no-enable-performance-insights")
            params_added=1
        fi
    fi

    # CloudWatch Logs Exports
    if [ -n "$LOG_EXPORTS" ]; then
        IFS=';' read -ra LOG_EXPORTS_ARRAY <<< "$LOG_EXPORTS"
        if [ "${#LOG_EXPORTS_ARRAY[@]}" -gt 0 ]; then
            local LOG_TYPES_JSON=""
            local first=true
            for log_type in "${LOG_EXPORTS_ARRAY[@]}"; do
                local trimmed_log_type=$(echo "$log_type" | xargs)
                if [ -n "$trimmed_log_type" ]; then
                     if [ "$first" = true ]; then
                        LOG_TYPES_JSON+="\"$trimmed_log_type\""
                        first=false
                     else
                        LOG_TYPES_JSON+=",\"$trimmed_log_type\""
                     fi
                fi
            done

            if [ -n "$LOG_TYPES_JSON" ]; then
                 CMD+=("--cloudwatch-logs-export-configuration" "{\"EnableLogTypes\":[$LOG_TYPES_JSON]}")
                 params_added=1
            fi
        fi
    fi

    # 何も更新パラメータがなければスキップ
    if [ "$params_added" -eq 0 ]; then
        log "${DB_IDENTIFIER} に更新可能なパラメータの変更はありません。"
        return 0
    fi

    log "実行コマンド: ${CMD[*]}"
    if ! "${CMD[@]}"; then
        log "エラー: インスタンス更新コマンドの実行に失敗しました。"
        return 1
    fi
    log "インスタンス更新コマンド発行完了: ${DB_IDENTIFIER}"
    return 0
}

# RDSインスタンスを作成する関数
create_rds_instance() {
    log "${DB_IDENTIFIER} の作成処理を開始 (リージョン: ${REGION})"

    # セキュリティグループ名からIDへの変換とリスト作成
    SECURITY_GROUP_IDS=()
    if [ -n "$VPC_SG_IDS" ]; then
        IFS=';' read -ra SG_NAMES_OR_IDS_ARRAY <<< "$VPC_SG_IDS"
        for sg in "${SG_NAMES_OR_IDS_ARRAY[@]}"; do
            if [ -z "$(echo "$sg" | xargs)" ]; then continue; fi

            sg_id=$(get_security_group_id "$(echo "$sg" | xargs)" "$REGION")
            if [ "$?" -ne 0 ]; then
                log "セキュリティグループIDの取得に失敗したため、インスタンス作成を中止します。"
                return 1
            fi
            SECURITY_GROUP_IDS+=("$sg_id")
        done
    fi

    # タグの準備
    local TAG_CMD_PART=()
    if [ -n "$TAGS" ]; then
        TAG_CMD_PART+=("--tags")
        IFS=';' read -ra TAG_PAIRS <<< "$TAGS"
        for tag_pair in "${TAG_PAIRS[@]}"; do
            local clean_tag_pair=$(echo "$tag_pair" | xargs)
            if [ -z "$clean_tag_pair" ]; then continue; fi

            if [[ "$clean_tag_pair" =~ ^([^=]+)=(.+)$ ]]; then
                 local key="${BASH_REMATCH[1]}"
                 local value="${BASH_REMATCH[2]}"
                 TAG_CMD_PART+=("Key=$(echo "$key" | xargs),Value=$(echo "$value" | xargs)")
            elif [[ "$clean_tag_pair" =~ ^([^=]+)$ ]]; then
                 local key="${BASH_REMATCH[1]}"
                 TAG_CMD_PART+=("Key=$(echo "$key" | xargs),Value=")
                 log "警告: タグ '$clean_tag_pair' は 'キー=値' の形式ではありません。Key=$(echo "$key" | xargs),Value= として処理します。"
            else
                 log "警告: 無効なタグ形式 '$clean_tag_pair' をスキップします。"
            fi
        done
    fi

    local CMD=()

    # スナップショットからの復元の場合
    if [ -n "$SNAPSHOT_IDENTIFIER" ]; then
        log "スナップショット ${SNAPSHOT_IDENTIFIER} からインスタンス ${DB_IDENTIFIER} を復元開始"
        CMD=(
            "aws" "rds" "restore-db-instance-from-db-snapshot"
            "--region" "$REGION"
            "--db-instance-identifier" "$DB_IDENTIFIER"
            "--db-snapshot-identifier" "$SNAPSHOT_IDENTIFIER"
            "--db-subnet-group-name" "$SUBNET_GROUP"
            "--no-cli-pager"
        )
        if [ -n "$INSTANCE_CLASS" ]; then
            CMD+=("--db-instance-class" "$INSTANCE_CLASS")
        fi
        if [ -n "$STORAGE_TYPE" ]; then
            CMD+=("--storage-type" "$STORAGE_TYPE")
        fi
        if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
            CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        fi
        if [ -n "$PUBLIC_ACCESS" ]; then
            if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--publicly-accessible"); fi
            if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-publicly-accessible"); fi
        fi
        if [ -n "$MULTI_AZ" ]; then
            if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--multi-az"); fi
            if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-multi-az"); fi
        fi
        if [ -n "$ENABLE_PERFORMANCE_INSIGHTS" ]; then
            if [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
                CMD+=("--enable-performance-insights")
                if [ -n "$PERFORMANCE_RETENTION" ]; then
                    CMD+=("--performance-insights-retention-period" "$PERFORMANCE_RETENTION")
                fi
            elif [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then
                CMD+=("--no-enable-performance-insights")
            fi
        fi
        if [ "${#TAG_CMD_PART[@]}" -gt 0 ]; then
            CMD+=("${TAG_CMD_PART[@]}")
        fi

    # ポイントインタイムリカバリの場合
    elif [ -n "$SOURCE_DB_IDENTIFIER" ]; then
        log "ソースインスタンス ${SOURCE_DB_IDENTIFIER} からインスタンス ${DB_IDENTIFIER} をポイントインタイムリカバリ開始"
        CMD=(
            "aws" "rds" "restore-db-instance-to-point-in-time"
            "--region" "$REGION"
            "--db-instance-identifier" "$DB_IDENTIFIER"
            "--source-db-instance-identifier" "$SOURCE_DB_IDENTIFIER"
            "--db-subnet-group-name" "$SUBNET_GROUP"
            "--use-latest-restorable-time"
            "--no-cli-pager"
        )
        if [ -n "$INSTANCE_CLASS" ]; then
            CMD+=("--db-instance-class" "$INSTANCE_CLASS")
        fi
        if [ -n "$STORAGE_TYPE" ]; then
            CMD+=("--storage-type" "$STORAGE_TYPE")
        fi
        if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
            CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        fi
        if [ -n "$PUBLIC_ACCESS" ]; then
            if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--publicly-accessible"); fi
            if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-publicly-accessible"); fi
        fi
        if [ -n "$MULTI_AZ" ]; then
            if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--multi-az"); fi
            if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-multi-az"); fi
        fi
        if [ -n "$ENABLE_PERFORMANCE_INSIGHTS" ]; then
            if [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
                CMD+=("--enable-performance-insights")
                if [ -n "$PERFORMANCE_RETENTION" ]; then
                    CMD+=("--performance-insights-retention-period" "$PERFORMANCE_RETENTION")
                fi
            elif [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then
                CMD+=("--no-enable-performance-insights")
            fi
        fi
        if [ "${#TAG_CMD_PART[@]}" -gt 0 ]; then
            CMD+=("${TAG_CMD_PART[@]}")
        fi

    # 新規作成の場合
    else
        log "インスタンス ${DB_IDENTIFIER} を新規作成開始"
        CMD=(
            "aws" "rds" "create-db-instance"
            "--region" "$REGION"
            "--db-instance-identifier" "$DB_IDENTIFIER"
            "--engine" "$ENGINE"
            "--engine-version" "$ENGINE_VERSION"
            "--db-instance-class" "$INSTANCE_CLASS"
            "--allocated-storage" "$ALLOCATED_STORAGE"
            "--storage-type" "$STORAGE_TYPE"
            "--db-subnet-group-name" "$SUBNET_GROUP"
            "--backup-retention-period" "$BACKUP_RETENTION"
            "--preferred-backup-window" "$BACKUP_WINDOW"
            "--preferred-maintenance-window" "$MAINTENANCE_WINDOW"
            "--no-cli-pager"
        )
        if [ -n "$MAX_ALLOCATED_STORAGE" ]; then
            CMD+=("--max-allocated-storage" "$MAX_ALLOCATED_STORAGE")
        fi
        if [ -n "$DB_NAME" ]; then
            CMD+=("--db-name" "$DB_NAME")
        fi
        if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
            CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        fi
        if [ -n "$PARAM_GROUP" ]; then
            CMD+=("--db-parameter-group-name" "$PARAM_GROUP")
        fi
        if [ -n "$OPT_GROUP" ]; then
            CMD+=("--option-group-name" "$OPT_GROUP")
        fi
        if [ -n "$PUBLIC_ACCESS" ]; then
            if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--publicly-accessible"); fi
            if [ "$(echo "$PUBLIC_ACCESS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-publicly-accessible"); fi
        fi
        if [ -n "$MULTI_AZ" ]; then
            if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--multi-az"); fi
            if [ "$(echo "$MULTI_AZ" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-multi-az"); fi
        fi
        if [ -n "$ENABLE_PERFORMANCE_INSIGHTS" ]; then
            if [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
                CMD+=("--enable-performance-insights")
                if [ -n "$PERFORMANCE_RETENTION" ]; then
                    CMD+=("--performance-insights-retention-period" "$PERFORMANCE_RETENTION")
                fi
            elif [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then
                CMD+=("--no-enable-performance-insights")
            fi
        fi
        if [ -n "$LOG_EXPORTS" ]; then
            IFS=';' read -ra LOG_EXPORTS_ARRAY <<< "$LOG_EXPORTS"
            if [ "${#LOG_EXPORTS_ARRAY[@]}" -gt 0 ]; then
                CMD+=("--enable-cloudwatch-logs-exports")
                for log_type in "${LOG_EXPORTS_ARRAY[@]}"; do
                    if [ -n "$(echo "$log_type" | xargs)" ]; then
                        CMD+=("$(echo "$log_type" | xargs)")
                    fi
                done
            fi
        fi
        # 認証情報の設定 (Secrets Manager 優先)
        if [ -n "$SECRET_MANAGER_ARN" ]; then
            log "${DB_IDENTIFIER}: Secrets Manager ARN を使用して認証情報を設定します。"
            CMD+=("--master-user-secret-arn" "$SECRET_MANAGER_ARN")
        elif [ -n "$MASTER_USERNAME" ] && [ -n "$MASTER_PASSWORD" ]; then
            log "${DB_IDENTIFIER}: マスターユーザー名とパスワードを使用して認証情報を設定します。"
            CMD+=("--master-username" "$MASTER_USERNAME")
            CMD+=("--master-user-password" "$MASTER_PASSWORD")
        else
            log "エラー: 新規作成には Secrets Manager ARN または マスターユーザー名/マスターパスワード ペアのどちらかが必要です。"
            return 1
        fi
        # タグ
        if [ "${#TAG_CMD_PART[@]}" -gt 0 ]; then
            CMD+=("${TAG_CMD_PART[@]}")
        fi
    fi

    if [ ${#CMD[@]} -eq 0 ]; then
        log "エラー: インスタンス作成/復元のためのコマンドが構築できませんでした。設定を確認してください。"
        return 1
    fi

    log "実行コマンド: ${CMD[*]}"
    if ! "${CMD[@]}"; then
        log "エラー: インスタンス作成/復元コマンドの実行に失敗しました。"
        return 1
    fi
    log "インスタンス作成/復元コマンド発行完了: ${DB_IDENTIFIER}"
    return 0
}

# --- メイン処理 ---
main() {
    # コマンドライン引数でCSVファイル名を取得
    CONFIG_CSV="$1"

    if [ -z "$CONFIG_CSV" ]; then
        error_exit "設定CSVファイルを指定してください。"
    fi

    if [ ! -f "$CONFIG_CSV" ]; then
        error_exit "設定CSVファイルが見つかりません: $CONFIG_CSV"
    fi

    log "設定ファイル ${CONFIG_CSV} を読み込み開始"

    # CSVファイルの内容を読み込んで処理
    while IFS=, read -r REGION DB_IDENTIFIER ENGINE ENGINE_VERSION INSTANCE_CLASS STORAGE_TYPE ALLOCATED_STORAGE MAX_ALLOCATED_STORAGE DB_NAME MASTER_USERNAME MASTER_PASSWORD VPC_SG_IDS SUBNET_GROUP PARAM_GROUP OPT_GROUP PUBLIC_ACCESS ENABLE_PERFORMANCE_INSIGHTS BACKUP_RETENTION BACKUP_WINDOW MAINTENANCE_WINDOW PERFORMANCE_RETENTION TAGS MULTI_AZ LOG_EXPORTS SNAPSHOT_IDENTIFIER SOURCE_DB_IDENTIFIER SECRET_MANAGER_ARN; do
        # ヘッダー行と空行をスキップ
        if [ "$(echo "$REGION" | xargs)" = "REGION" ]; then continue; fi
        if [ -z "$(echo "$REGION" | xargs)" ] && [ -z "$(echo "$DB_IDENTIFIER" | xargs)" ]; then continue; fi

        log "--- ${DB_IDENTIFIER} の処理開始 ---"

        # 各変数の前後の空白を削除
        REGION=$(echo "$REGION" | xargs)
        DB_IDENTIFIER=$(echo "$DB_IDENTIFIER" | xargs)
        ENGINE=$(echo "$ENGINE" | xargs)
        ENGINE_VERSION=$(echo "$ENGINE_VERSION" | xargs)
        INSTANCE_CLASS=$(echo "$INSTANCE_CLASS" | xargs)
        STORAGE_TYPE=$(echo "$STORAGE_TYPE" | xargs)
        ALLOCATED_STORAGE=$(echo "$ALLOCATED_STORAGE" | xargs)
        MAX_ALLOCATED_STORAGE=$(echo "$MAX_ALLOCATED_STORAGE" | xargs)
        DB_NAME=$(echo "$DB_NAME" | xargs)
        MASTER_USERNAME=$(echo "$MASTER_USERNAME" | xargs)
        MASTER_PASSWORD=$(echo "$MASTER_PASSWORD" | xargs)
        VPC_SG_IDS=$(echo "$VPC_SG_IDS" | xargs)
        SUBNET_GROUP=$(echo "$SUBNET_GROUP" | xargs)
        PARAM_GROUP=$(echo "$PARAM_GROUP" | xargs)
        OPT_GROUP=$(echo "$OPT_GROUP" | xargs)
        PUBLIC_ACCESS=$(echo "$PUBLIC_ACCESS" | xargs)
        ENABLE_PERFORMANCE_INSIGHTS=$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | xargs)
        BACKUP_RETENTION=$(echo "$BACKUP_RETENTION" | xargs)
        BACKUP_WINDOW=$(echo "$BACKUP_WINDOW" | xargs)
        MAINTENANCE_WINDOW=$(echo "$MAINTENANCE_WINDOW" | xargs)
        PERFORMANCE_RETENTION=$(echo "$PERFORMANCE_RETENTION" | xargs)
        TAGS=$(echo "$TAGS" | xargs)
        MULTI_AZ=$(echo "$MULTI_AZ" | xargs)
        LOG_EXPORTS=$(echo "$LOG_EXPORTS" | xargs)
        SNAPSHOT_IDENTIFIER=$(echo "$SNAPSHOT_IDENTIFIER" | xargs)
        SOURCE_DB_IDENTIFIER=$(echo "$SOURCE_DB_IDENTIFIER" | xargs)
        SECRET_MANAGER_ARN=$(echo "$SECRET_MANAGER_ARN" | xargs)

        # 必須項目チェック
        if [ -z "$DB_IDENTIFIER" ] || [ -z "$REGION" ] || [ -z "$ENGINE" ]; then
             log "エラー: ${DB_IDENTIFIER} 設定行に必須パラメータ (REGION, DB_IDENTIFIER, ENGINE) の不足または無効な値があります。この行はスキップします。"
             continue
        fi

        # 復元タイプと新規作成の組み合わせチェック
        if [ -n "$SNAPSHOT_IDENTIFIER" ] && [ -n "$SOURCE_DB_IDENTIFIER" ]; then
             log "エラー: ${DB_IDENTIFIER} 設定行で SNAPSHOT_IDENTIFIER と SOURCE_DB_IDENTIFIER の両方が指定されています。どちらか一方のみを指定してください。この行はスキップします。"
             continue
        fi

        # 新規作成時の必須パラメータ検証
        if [ -z "$SNAPSHOT_IDENTIFIER" ] && [ -z "$SOURCE_DB_IDENTIFIER" ]; then
             # 認証情報検証
             if [ -z "$SECRET_MANAGER_ARN" ] && ( [ -z "$MASTER_USERNAME" ] || [ -z "$MASTER_PASSWORD" ] ); then
                  log "エラー: ${DB_IDENTIFIER} 設定行で新規作成のための Secrets Manager ARN または マスターユーザー名/マスターパスワード ペアが指定されていません。この行はスキップします。"
                  continue
             fi
             # DB Subnet Groupが必須
             if [ -z "$SUBNET_GROUP" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で SUBNET_GROUP が指定されていません。新規作成時には必須です。この行はスキップします。"
               continue
             fi
             # EngineVersionが必須
             if [ -z "$ENGINE_VERSION" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で ENGINE_VERSION が指定されていません。新規作成時には必須です。"
               continue
             fi
             # DB Instance Classが必須
             if [ -z "$INSTANCE_CLASS" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で INSTANCE_CLASS が指定されていません。新規作成時には必須です。"
               continue
             fi
             # Allocated Storageが必須
             if [ -z "$ALLOCATED_STORAGE" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で ALLOCATED_STORAGE が指定されていません。新規作成時には必須です。"
               continue
             fi
        else # 復元系の場合の必須パラメータ検証
             # DB Subnet Groupが必須
             if [ -z "$SUBNET_GROUP" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で SUBNET_GROUP が指定されていません。復元時には必須です。この行はスキップします。"
               continue
             fi
        fi

        # インスタンスの存在をチェック
        local instance_status=$(check_instance_exists "$DB_IDENTIFIER" "$REGION")

        if [ -n "$instance_status" ]; then
            log "インスタンス ${DB_IDENTIFIER} は既に存在します (状態: ${instance_status})。"
            # 存在するインスタンスに対してはパラメータ更新を行う
            update_rds_instance
        else
            log "インスタンス ${DB_IDENTIFIER} は存在しません。新規作成または復元を開始します。"
            create_rds_instance
        fi

        log "--- ${DB_IDENTIFIER} の処理完了 ---"
    done < <(tail -n +2 "$CONFIG_CSV")

    log "CSVファイルのすべてのエントリの処理が完了しました。"
}

# スクリプト実行時にmain関数を呼び出し、コマンドライン引数を渡す
main "$@"