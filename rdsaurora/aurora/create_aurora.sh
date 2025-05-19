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
# SG ID (sg-...) が渡された場合はそのまま返し、SG名を渡された場合は検索してIDを返す
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
            --no-cli-pager 2>/dev/null) # エラー出力を抑制

        if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
            log "エラー: セキュリティグループ '$sg_name_or_id' (リージョン $region) が見つかりません。"
            return 1 # 呼び出し元でエラー判定できるように非ゼロを返す
        fi
    fi

    echo "$sg_id"
    return 0 # 成功
}

# クラスターの存在をチェックする関数
# 存在する場合、そのステータスを返す
check_cluster_exists() {
    local cluster_id="$1"
    local region="$2"
    local status=""

    status=$(aws rds describe-db-clusters \
        --region "$region" \
        --db-cluster-identifier "$cluster_id" \
        --query 'DBClusters[0].Status' \
        --output text \
        --no-cli-pager 2>/dev/null)

    # 'None'はAWS CLIで存在しない場合にテキスト出力されることがある
    if [ -z "$status" ] || [ "$status" = "None" ]; then
        echo "" # 存在しない場合は空文字列を返す
    else
        echo "$status"
    fi
}

# update_aurora_cluster: 既存クラスターのパラメータを更新する関数
# この関数はクラスターレベルのパラメータのみを扱います。インスタンスの管理は manage_aurora_instances で行います。
update_aurora_cluster() {
    log "${DB_IDENTIFIER} のパラメータ更新を開始 (リージョン: ${REGION})"

    # セキュリティグループ名からIDへの変換とリスト作成
    SECURITY_GROUP_IDS=() # 配列を初期化
    if [ -n "$SECURITY_GROUPS" ]; then
        IFS=';' read -ra SG_NAMES_OR_IDS_ARRAY <<< "$SECURITY_GROUPS"
        for sg in "${SG_NAMES_OR_IDS_ARRAY[@]}"; do
            if [ -z "$(echo "$sg" | xargs)" ]; then continue; fi # 空要素はスキップ

            sg_id=$(get_security_group_id "$(echo "$sg" | xargs)" "$REGION")
            if [ "$?" -ne 0 ]; then # get_security_group_id が失敗した場合
                log "セキュリティグループIDの取得に失敗したため、クラスター更新を中止します。"
                return 1
            fi
            SECURITY_GROUP_IDS+=("$sg_id")
        done
    fi

    local CMD=("aws" "rds" "modify-db-cluster" \
        "--region" "$REGION" \
        "--db-cluster-identifier" "$DB_IDENTIFIER" \
        "--apply-immediately" \
        "--no-cli-pager")

    local params_added=0 # 更新パラメータが追加されたか判定するフラグ

    # 更新可能なパラメータを追加
    if [ -n "$BACKUP_RETENTION" ]; then CMD+=("--backup-retention-period" "$BACKUP_RETENTION"); params_added=1; fi
    if [ -n "$PREFERRED_BACKUP_WINDOW" ]; then CMD+=("--preferred-backup-window" "$PREFERRED_BACKUP_WINDOW"); params_added=1; fi
    if [ -n "$PREFERRED_MAINTENANCE_WINDOW" ]; then CMD+=("--preferred-maintenance-window" "$PREFERRED_MAINTENANCE_WINDOW"); params_added=1; fi
    if [ -n "$CLUSTER_PARAMETER_GROUP" ]; then CMD+=("--db-cluster-parameter-group-name" "$CLUSTER_PARAMETER_GROUP"); params_added=1; fi

    # Security Group IDリストを結合して追加
    if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
        CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        params_added=1
    fi
    # IAM AuthのTRUE/FALSE両方に対応
    if [ -n "$IAM_AUTH" ]; then
        if [ "$(echo "$IAM_AUTH" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--enable-iam-database-authentication"); params_added=1; fi
        if [ "$(echo "$IAM_AUTH" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-enable-iam-database-authentication"); params_added=1; fi
    fi

    # CloudWatch Logs Exports (for modify)
    # modify-db-cluster では CloudwatchLogsExportConfiguration を使用 (JSON形式)
    if [ -n "$CLOUDWATCH_LOGS_EXPORTS" ]; then
        IFS=';' read -ra LOG_EXPORTS_ARRAY <<< "$CLOUDWATCH_LOGS_EXPORTS"
        if [ "${#LOG_EXPORTS_ARRAY[@]}" -gt 0 ]; then
            # Construct JSON array string: ["type1","type2"]
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
                 CMD+=("--cloudwatch-logs-export-configuration" "{\"EnableLogTypes\":[$LOG_TYPES_JSON]}") # Use JSON format
                 params_added=1
            fi
        else
             log "${DB_IDENTIFIER}: CLOUDWATCH_LOGS_EXPORTS が空文字列です。ログエクスポート設定は変更しません。"
        fi
    fi

    # Deletion ProtectionのTRUE/FALSE両方に対応
    if [ -n "$DELETION_PROTECTION" ]; then
        if [ "$(echo "$DELETION_PROTECTION" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then CMD+=("--deletion-protection"); params_added=1; fi
        if [ "$(echo "$DELETION_PROTECTION" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then CMD+=("--no-deletion-protection"); params_added=1; fi
    fi

    # Performance Insightsの有効/無効と保持期間に対応
    if [ -n "$ENABLE_PERFORMANCE_INSIGHTS" ]; then
        if [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
            CMD+=("--enable-performance-insights")
            params_added=1
            if [ -n "$PERFORMANCE_INSIGHTS_RETENTION" ]; then
                 local valid_retention_values=(7 31 62 93 124 155 186 217 248 279 310 341 372 403 434 465 496 527 558 589 620 651 682 713 731)
                 if [[ " ${valid_retention_values[*]} " =~ " $PERFORMANCE_INSIGHTS_RETENTION " ]]; then
                    CMD+=("--performance-insights-retention-period" "$PERFORMANCE_INSIGHTS_RETENTION")
                 else
                    log "警告: 無効なPerformance Insightsリテンション期間 '$PERFORMANCE_INSIGHTS_RETENTION' が指定されました。許可される値: ${valid_retention_values[*]}"
                 fi
            fi
        elif [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "FALSE" ]; then
            CMD+=("--no-enable-performance-insights")
            params_added=1
        fi
    fi

    # ストレージタイプの更新
    if [ -n "$AURORA_STORAGE_TYPE" ]; then
        CMD+=("--storage-type" "$AURORA_STORAGE_TYPE")
        params_added=1
    fi

    # Secrets Manager/パスワード更新
    if [ "$(echo "$MANAGE_MASTER_PASSWORD"  | tr -d '\r' | xargs | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
        CMD+=("--manage-master-user-password")
        params_added=1
    elif  [ "$(echo "$MANAGE_MASTER_PASSWORD"  | tr -d '\r' | xargs | tr '[:lower:]' '[:upper:]')" != "TRUE" ] && [ -n "$MASTER_USERNAME" ] && [ -n "$MASTER_PASSWORD" ]; then
        CMD+=("--no-manage-master-user-password")
        CMD+=("--master-user-password" "$MASTER_PASSWORD")
        params_added=1
    fi

    # 何も更新パラメータがなければスキップ
    if [ "$params_added" -eq 0 ]; then
        log "${DB_IDENTIFIER} に更新可能なクラスターパラメータの変更はありません。"
        return 0
    fi

    log "実行コマンド: ${CMD[*]}"
    if ! "${CMD[@]}"; then
        log "エラー: クラスターパラメータ更新コマンドの実行に失敗しました。"
        return 1
    fi
    log "クラスターパラメータ更新コマンド発行完了: ${DB_IDENTIFIER}"
    return 0
}


# create_aurora_cluster: Auroraクラスターを作成（新規、スナップショット、PITR）する関数
# この関数はクラスター自体を作成/復元する責任を持ちます。成功した場合0を返します。
create_aurora_cluster() {
    log "${DB_IDENTIFIER} の作成処理を開始 (リージョン: ${REGION})"

    # セキュリティグループ名からIDへの変換とリスト作成
    SECURITY_GROUP_IDS=() # 配列を初期化
    if [ -n "$SECURITY_GROUPS" ]; then
        IFS=';' read -ra SG_NAMES_OR_IDS_ARRAY <<< "$SECURITY_GROUPS"
        for sg in "${SG_NAMES_OR_IDS_ARRAY[@]}"; do
            if [ -z "$(echo "$sg" | xargs)" ]; then continue; fi # 空要素はスキップ

            sg_id=$(get_security_group_id "$(echo "$sg" | xargs)" "$REGION")
            if [ "$?" -ne 0 ]; then # get_security_group_id が失敗した場合
                 log "セキュリティグループIDの取得に失敗したため、クラスター作成を中止します。"
                 return 1 # 呼び出し元でエラーを捕捉させるために戻り値で失敗を通知
            fi
            SECURITY_GROUP_IDS+=("$sg_id")
        done
    fi

    local CMD=()

    # タグの準備 (作成時、復元時共通)
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

    # スナップショットからの復元の場合
    if [ -n "$SNAPSHOT_IDENTIFIER" ]; then
        log "スナップショット ${SNAPSHOT_IDENTIFIER} からクラスター ${DB_IDENTIFIER} を復元開始"
        CMD=(
            "aws" "rds" "restore-db-cluster-from-snapshot"
            "--region" "$REGION"
            "--db-cluster-identifier" "$DB_IDENTIFIER"
            "--snapshot-identifier" "$SNAPSHOT_IDENTIFIER"
            "--engine" "$ENGINE" # エンジンはスナップショットから継承されるが、CLIでは指定が必要な場合がある
            "--db-subnet-group-name" "$DB_SUBNET_GROUP"
            # ENGINE_VERSION を復元時に指定してアップグレードする場合 (主要パラメータの後)
            # snapshot restore does *not* support --allow-major-version-upgrade
            # ここにENGINE_VERSIONを追加
            "--no-cli-pager"
        )
        if [ -n "$ENGINE_VERSION" ]; then
             CMD+=("--engine-version" "$ENGINE_VERSION")
             log "注意: スナップショット復元時の ENGINE_VERSION 指定は、互換性のあるマイナーバージョンアップまたは復元後のメジャーバージョンアップを想定しています。restore-db-cluster-from-snapshot に --allow-major-version-upgrade はありません。"
        fi
        # 復元時もセキュリティグループを指定可能 (オプション)
        if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
           CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        fi
        # 復元時もタグを指定可能 (オプション)
        if [ "${#TAG_CMD_PART[@]}" -gt 0 ]; then
           CMD+=("${TAG_CMD_PART[@]}")
        fi

    # ポイントインタイムリカバリの場合
    elif [ -n "$SOURCE_DB_IDENTIFIER" ]; then
        log "ソースクラスター ${SOURCE_DB_IDENTIFIER} からクラスター ${DB_IDENTIFIER} をポイントインタイムリカバリ開始"
        CMD=(
            "aws" "rds" "restore-db-cluster-to-point-in-time"
            "--region" "$REGION"
            "--db-cluster-identifier" "$DB_IDENTIFIER"
            "--db-subnet-group-name" "$DB_SUBNET_GROUP"
            "--source-db-cluster-identifier" "$SOURCE_DB_IDENTIFIER"
            "--use-latest-restorable-time"
            # ENGINE_VERSION をPITR復元時に指定してアップグレードする場合 (主要パラメータの後)
            # PITRではallow-major-version-upgradeが使用可能。
            "--no-cli-pager"
        )
        # 復元時もセキュリティグループを指定可能 (オプション)
        if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
           CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        fi
        # 復元時もタグを指定可能 (オプション)
        if [ "${#TAG_CMD_PART[@]}" -gt 0 ]; then
           CMD+=("${TAG_CMD_PART[@]}")
        fi

    # 新規作成の場合
    else
        log "クラスター ${DB_IDENTIFIER} を新規作成開始"
        CMD=(
            "aws" "rds" "create-db-cluster"
            "--region" "$REGION"
            "--db-cluster-identifier" "$DB_IDENTIFIER"
            "--engine" "$ENGINE"
            "--engine-version" "$ENGINE_VERSION"
            "--db-subnet-group-name" "$DB_SUBNET_GROUP"
            "--backup-retention-period" "$BACKUP_RETENTION"
            "--preferred-backup-window" "$PREFERRED_BACKUP_WINDOW"
            "--preferred-maintenance-window" "$PREFERRED_MAINTENANCE_WINDOW"
            "--no-cli-pager"
        )
        # 認証情報の設定 (Secrets Manager 優先)
        if [ "$(echo "$MANAGE_MASTER_PASSWORD" | tr -d '\r' | xargs | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
            log "${DB_IDENTIFIER}: Secrets Manager を使用して認証情報を設定します。"
            CMD+=("--master-username" "$MASTER_USERNAME")
            CMD+=("--manage-master-user-password")
        elif  [ "$(echo "$MANAGE_MASTER_PASSWORD" | tr -d '\r' | xargs | tr '[:lower:]' '[:upper:]')" != "TRUE" ] && [ -n "$MASTER_USERNAME" ] && [ -n "$MASTER_PASSWORD" ]; then
            log "${DB_IDENTIFIER}: マスターユーザー名とパスワードを使用して認証情報を設定します。"
            CMD+=("--master-username" "$MASTER_USERNAME")
            CMD+=("--master-user-password" "$MASTER_PASSWORD")
        else
            log "エラー: 新規作成には MANAGE_MASTER_PASSWORD または マスターユーザー名/マスターパスワード ペアのどちらかが必要です。"
            return 1
        fi

        # CSVから追加したパラメータ
        if [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ]; then
            CMD+=("--vpc-security-group-ids" "${SECURITY_GROUP_IDS[@]}")
        fi
        if [ -n "$CLUSTER_PARAMETER_GROUP" ]; then
            CMD+=("--db-cluster-parameter-group-name" "$CLUSTER_PARAMETER_GROUP")
        fi
        if [ -n "$DB_NAME" ]; then
            CMD+=("--database-name" "$DB_NAME")
        fi
        if [ "$(echo "$IAM_AUTH" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
            CMD+=("--enable-iam-database-authentication")
        fi
        # CloudWatch Logs Exports (for create) - Use space-separated list
        if [ -n "$CLOUDWATCH_LOGS_EXPORTS" ]; then
            IFS=';' read -ra LOG_EXPORTS_ARRAY <<< "$CLOUDWATCH_LOGS_EXPORTS"
            if [ "${#LOG_EXPORTS_ARRAY[@]}" -gt 0 ]; then
                CMD+=("--enable-cloudwatch-logs-exports")
                for log_type in "${LOG_EXPORTS_ARRAY[@]}"; do
                    if [ -n "$(echo "$log_type" | xargs)" ]; then
                         CMD+=("$(echo "$log_type" | xargs)")
                    fi
                done
            fi
        fi
        if [ "$(echo "$DELETION_PROTECTION" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
            CMD+=("--deletion-protection")
        fi
        if [ "$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | tr '[:lower:]' '[:upper:]')" = "TRUE" ]; then
            CMD+=("--enable-performance-insights")
            if [ -n "$PERFORMANCE_INSIGHTS_RETENTION" ]; then
                 CMD+=("--performance-insights-retention-period" "$PERFORMANCE_INSIGHTS_RETENTION")
            fi
        fi
        # タグ
        if [ "${#TAG_CMD_PART[@]}" -gt 0 ]; then
             CMD+=("${TAG_CMD_PART[@]}")
        fi
        # ストレージタイプ
        if [ -n "$AURORA_STORAGE_TYPE" ]; then
            CMD+=("--storage-type" "$AURORA_STORAGE_TYPE")
        fi
    fi

    if [ ${#CMD[@]} -eq 0 ]; then
        log "エラー: クラスター作成/復元のためのコマンドが構築できませんでした。設定を確認してください。"
        return 1
    fi

    log "実行コマンド: ${CMD[*]}"
    if ! "${CMD[@]}"; then
        log "エラー: クラスター作成/復元コマンドの実行に失敗しました。"
        return 1
    fi
    log "クラスター作成/復元コマンド発行完了: ${DB_IDENTIFIER}"
    return 0
}


# manage_aurora_create_instances: Auroraクラスターのインスタンスを指定された総数だけ初期作成する関数
# この関数は main 関数から、クラスター新規作成成功時に一度だけ呼ばれることを想定しています。
manage_aurora_create_instances() {
    # 目標インスタンス総数のバリデーション
    local target_total_count=${AURORA_INSTANCE_COUNT:-1}
    # manage_aurora_create_instances は main で target_total_count >= 1 が確認されてから呼ばれるが、念のため再チェック
    if ! [[ "$target_total_count" =~ ^[0-9]+$ ]] || [ "$target_total_count" -lt 1 ]; then
         log "エラー: manage_aurora_create_instances が無効な目標インスタンス総数 '$target_total_count' で呼ばれました。1以上の整数を指定してください。インスタンス作成をスキップします。"
         return 1
    fi

    if [ -z "$DB_INSTANCE_CLASS" ]; then
        log "エラー: DB_INSTANCE_CLASS が指定されていません。インスタンス作成中止。"
        return 1
    fi

    log "新規作成: $target_total_count 個のインスタンスを作成します。"
    # インスタンスは ${DB_IDENTIFIER}-instance-1 から連番で作成
    for ((i=1; i<=target_total_count; i++)); do
        local new_instance_id="${DB_IDENTIFIER}-instance-${i}"
        log "インスタンス $new_instance_id を作成します..."

        # コマンドの成否をチェック
        if ! aws rds create-db-instance \
            --region "$REGION" \
            --db-instance-identifier "$new_instance_id" \
            --db-cluster-identifier "$DB_IDENTIFIER" \
            --engine "$ENGINE" \
            --db-instance-class "$DB_INSTANCE_CLASS" \
            ${INSTANCE_PARAMETER_GROUP:+--db-parameter-group-name "$INSTANCE_PARAMETER_GROUP"} \
            $(if [ "$PUBLICLY_ACCESSIBLE" = "true" ]; then echo "--publicly-accessible"; elif [ "$PUBLICLY_ACCESSIBLE" = "false" ]; then echo "--no-publicly-accessible"; fi) \
            --no-cli-pager; then
            log "警告: インスタンス $new_instance_id の作成コマンド発行に失敗しました。手動での確認・作成が必要かもしれません。"
            # 作成失敗しても他のインスタンスの処理は続ける
        else
            log "インスタンス作成コマンド発行成功: $new_instance_id"
        fi
    done

    log "新規インスタンス作成コマンド発行完了。"
    return 0 # コマンド発行成功でOKとする（実際の完了は非同期）
}

# manage_aurora_instances: 既存Auroraクラスターのリードレプリカ数を調整する関数
# この関数は main 関数から、クラスターが既に存在し、かつ AURORA_INSTANCE_COUNT >= 0 の場合に呼ばれることを想定しています。
manage_aurora_instances() {
    log "${DB_IDENTIFIER} のインスタンス管理を開始 (リージョン: ${REGION})"

    # 目標インスタンス総数の取得とバリデーション (main でチェック済みだが念のため)
    local target_total_count=${AURORA_INSTANCE_COUNT:-1}
    if ! [[ "$target_total_count" =~ ^[0-9]+$ ]] || [ "$target_total_count" -lt 0 ]; then # 0以上を許可
         log "エラー: manage_aurora_instances が無効な目標インスタンス総数 '$target_total_count' で呼ばれました。0以上の整数を指定してください。インスタンス管理をスキップします。"
         return 1
    fi


    # 目標リードレプリカ数 = 目標インスタンス総数 - 1 (プライマリ)
    # 目標総数0の場合は、目標レプリカ数は -1 となり、全てのレプリカが削除対象になる
    local target_replica_count=$((target_total_count - 1))
    log "目標のリードレプリカ数: $target_replica_count (目標インスタンス総数 $target_total_count)"


    # クラスターメンバー情報を取得してライターインスタンスを特定 (プライマリの正確な特定)
    local writer_instance_id=""
    local cluster_members_output
    # main 関数でクラスター存在チェック後に呼ばれるため、情報取得は成功するはずだが、念のためチェック
    cluster_members_output=$(aws rds describe-db-clusters \
        --region "$REGION" \
        --db-cluster-identifier "$DB_IDENTIFIER" \
        --query 'DBClusters[0].DBClusterMembers[*].[DBInstanceIdentifier,IsClusterWriter]' \
        --output text \
        --no-cli-pager 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$cluster_members_output" ] || [[ "$cluster_members_output" == *"None"* ]]; then
        log "エラー: クラスター ${DB_IDENTIFIER} の情報取得に失敗しました（manage_aurora_instances 呼び出し時）。インスタンス管理をスキップします。クラスターの状態を確認してください。"
        return 1 # インスタンス管理ができない状態
    fi

    # 出力からライターインスタンスIDを抽出
    while read -r instance_id is_writer; do
        if [ "$is_writer" = "True" ]; then
            writer_instance_id="$instance_id"
            break # ライターが見つかったらループを抜ける
        fi
    done <<< "$cluster_members_output"

    # ライターが特定できない場合はエラー (プライマリが存在しない、またはまだ 'writer' ロールになっていない)
    if [ -z "$writer_instance_id" ]; then
        log "エラー: クラスター ${DB_IDENTIFIER} のライターインスタンスを特定できませんでした。インスタンス管理をスキップします。クラスターの状態を確認してください。"
        return 1 # ライターが特定できない場合は管理できない
    fi
    # log "DEBUG: Writer instance ID: $writer_instance_id" # デバッグ用


    # クラスターに関連付けられたすべてのインスタンスIDを取得し、リードレプリカと全インスタンスのリストを構築
    local current_replicas=() # リードレプリカのIDを格納
    local all_instance_ids=() # 全インスタンスのIDを格納 (最大番号検索用)

    # aws rds describe-db-instances の出力を変数に読み込む
    # --output text とこのクエリの場合、インスタンスIDはタブ区切りで1行に出力される模様
    local all_instances_line
    all_instances_line=$(aws rds describe-db-instances \
        --region "$REGION" \
        --filter "Name=db-cluster-id,Values=$DB_IDENTIFIER" \
        --query 'DBInstances[*].DBInstanceIdentifier' \
        --output text \
        --no-cli-pager 2>/dev/null)

    # デバッグ用 (必要に応じてコメント解除)
    # log "DEBUG: Raw all_instances_line: '$all_instances_line'"
    # log "DEBUG: Raw all_instances_line Hex: $(echo -n "$all_instances_line" | hexdump -C)"

    if [ -z "$all_instances_line" ]; then
        # インスタンスが一つも見つからないケース。通常はライターがいるはずなのでエラーとする
        log "エラー: クラスター ${DB_IDENTIFIER} に関連付けられたインスタンスが一つも見つかりませんでした。(describe-db-instances 出力なし) インスタンス管理をスキップします。"
        return 1
    fi

    # IFS (Internal Field Separator) を使って、読み込んだ文字列をスペースやタブ、改行で分割し、一時的な配列に格納
    # read -a で配列に読み込む。-r は引き続き使用し、バックスラッシュを無効化
    local old_IFS="$IFS" # 現在のIFSを保存
    IFS=$' \t\n' # 区切り文字をスペース、タブ、改行に設定
    local all_instance_ids_temp_array=() # 分割格納用の一時配列
    read -r -a all_instance_ids_temp_array <<< "$all_instances_line" # 文字列を配列に読み込み

    IFS="$old_IFS" # IFSを元の設定に戻す

    # デバッグ用 (必要に応じてコメント解除)
    # log "DEBUG: all_instance_ids_temp_array (${#all_instance_ids_temp_array[@]} elements):"
    # for debug_i in "${!all_instance_ids_temp_array[@]}"; do
    #     log "DEBUG:   Element $debug_i: '${all_instance_ids_temp_array[$debug_i]}'"
    #     log "DEBUG:   Element $debug_i Hex: $(echo -n "${all_instance_ids_temp_array[$debug_i]}" | hexdump -C)"
    # done

    # 一時配列から、最終的な all_instance_ids 配列と current_replicas 配列を構築
    # これにより、空要素や不正な要素が混入するのを防ぎ、各要素がクリーンなインスタンスIDになるようにする
    all_instance_ids=() # 最終的な全インスタンスID配列をクリア
    current_replicas=() # リードレプリカ配列をクリア

    for instance_id in "${all_instance_ids_temp_array[@]}"; do
         # 各要素の前後の空白・タブ・改行を除去し、空でないことを確認
         local trimmed_instance_id=$(echo "$instance_id" | xargs)
         if [ -n "$trimmed_instance_id" ]; then
             all_instance_ids+=("$trimmed_instance_id") # 全インスタンスIDリストに追加

             # ライター以外のインスタンスをリードレプリカリストに追加
             if [ "$trimmed_instance_id" != "$writer_instance_id" ]; then
                 current_replicas+=("$trimmed_instance_id") # リードレプリカリストに追加
             fi
         fi
    done

    # 全インスタンスリストが空でないかチェック (分割・フィルタリング後)
    # 通常はライターが含まれるので1以上になるはず
    if [ ${#all_instance_ids[@]} -eq 0 ]; then
        log "エラー: クラスター ${DB_IDENTIFIER} に関連付けられたインスタンスが一つも見つかりませんでした。(Splitting resulted in empty list) インスタンス管理をスキップします。"
        return 1
    fi


    local current_replica_count=${#current_replicas[@]}
    log "現在のライターインスタンス: $writer_instance_id"
    log "現在のリードレプリカ数: $current_replica_count"
    log "現在のインスタンス総数: ${#all_instance_ids[@]}" # 全インスタンス総数もログに出す


    local num_to_delete=0
    local num_to_create=0

    # 作成または削除が必要なリードレプリカ数を正確に計算
    # 目標リードレプリカ数が負数になる場合（目標総数0の場合）、削除数は現在のレプリカ数全てとなる
    if [ "$current_replica_count" -gt "$target_replica_count" ]; then
        num_to_delete=$((current_replica_count - target_replica_count))
    elif [ "$current_replica_count" -lt "$target_replica_count" ]; then # 負数になる場合は削除、正数になる場合は作成
        num_to_create=$((target_replica_count - current_replica_count))
    fi


    # --- Deletion Logic (only for replicas) ---
    if [ "$num_to_delete" -gt 0 ]; then
        log "リードレプリカを $num_to_delete 個削除します。"

        # 削除対象レプリカを決定（current_replicas リストはすでにライターを除外したレプリカのみ）
        # current_replicas 配列の末尾から削除するのが一般的（新しく作られたインスタンスから消す）
        # ループ範囲は current_replica_count-1 から target_replica_count まで。
        for ((i=current_replica_count-1; i>=target_replica_count; i--)); do
            local instance_to_delete="${current_replicas[$i]}"
            # デバッグ用 (必要に応じてコメント解除)
            # log "DEBUG: instance_to_delete in deletion loop: '$instance_to_delete'"
            # log "DEBUG: instance_to_delete Hex in deletion loop: $(echo -n "$instance_to_delete" | hexdump -C)"

            log "インスタンス $instance_to_delete を削除します..."

            # aws rds delete-db-instance コマンドを実行
            # コマンドの成否をチェック
            if ! aws rds delete-db-instance \
                --region "$REGION" \
                --db-instance-identifier "$instance_to_delete" \
                --skip-final-snapshot \
                --no-cli-pager; then
                log "警告: インスタンス $instance_to_delete の削除コマンド発行に失敗しました。手動での確認・削除が必要かもしれません。"
                # 削除失敗しても他のインスタンスの処理は続ける
            else
                log "インスタンス削除コマンド発行成功: $instance_to_delete"
            fi
        done
    else
        log "削除が必要なリードレプリカはありません。"
    fi

    # --- Creation Logic (only for replicas) ---
    if [ "$num_to_create" -gt 0 ]; then
        log "リードレプリカを $num_to_create 個作成します。"

        # 最大の "-番号" を探す (全インスタンスIDリストから)
        local max_num=0
        # all_instance_ids 配列（ライター含む全てのインスタンスIDが格納されている）をループ
        for instance_id in "${all_instance_ids[@]}"; do
            # インスタンス名の末尾が "-数字" の形式かチェック
            if [[ "$instance_id" =~ -([0-9]+)$ ]]; then
                local num=${BASH_REMATCH[1]} # 数字部分をキャプチャ
                [ "$num" -gt "$max_num" ] && max_num=$num # 最大値を更新
            fi
        done

        # インスタンスクラスが指定されているか確認 (作成には必須)
        if [ -z "$DB_INSTANCE_CLASS" ]; then
             log "エラー: DB_INSTANCE_CLASS が指定されていません。インスタンス作成には必須です。"
             return 1 # インスタンスクラスがない場合は作成できない
        fi

        # 新しいリードレプリカインスタンスを作成
        for ((i=1; i<=num_to_create; i++)); do
            local new_instance_num=$((max_num + i)) # 最大番号+1, +2, ...
            local new_instance_id="${DB_IDENTIFIER}-instance-${new_instance_num}"

            log "インスタンス $new_instance_id を作成します..."

            # aws rds create-db-instance コマンドを実行
            # コマンドの成否をチェック
            if ! aws rds create-db-instance \
                --region "$REGION" \
                --db-instance-identifier "$new_instance_id" \
                --db-cluster-identifier "$DB_IDENTIFIER" \
                --engine "$ENGINE" \
                --db-instance-class "$DB_INSTANCE_CLASS" \
                ${INSTANCE_PARAMETER_GROUP:+--db-parameter-group-name "$INSTANCE_PARAMETER_GROUP"} \
                $(if [ "$PUBLICLY_ACCESSIBLE" = "true" ]; then echo "--publicly-accessible"; elif [ "$PUBLICLY_ACCESSIBLE" = "false" ]; then echo "--no-publicly-accessible"; fi) \
                --no-cli-pager; then
                log "警告: インスタンス $new_instance_id の作成コマンド発行に失敗しました。手動での確認・作成が必要かもしれません。"
                # 作成失敗しても他のインスタンスの処理は続ける
            else
                log "インスタンス作成コマンド発行成功: $new_instance_id"
            fi
        done
    else
        log "作成が必要なリードレプリカはありません。"
    fi

    log "${DB_IDENTIFIER} のインスタンス管理が完了しました。"
    return 0 # コマンド発行成功でOKとする（実際の完了は非同期）
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
    # tail -n +2 でヘッダー行をスキップ
    # IFS=, で区切り文字をカンマに設定
    # read -r でバックスラッシュをそのまま読み込む
    # 各カラムを適切な変数に割り当て
    while IFS=, read -r REGION DB_IDENTIFIER ENGINE ENGINE_VERSION DB_INSTANCE_CLASS CLUSTER_PARAMETER_GROUP INSTANCE_PARAMETER_GROUP SECURITY_GROUPS DB_SUBNET_GROUP MASTER_USERNAME MASTER_PASSWORD DB_NAME BACKUP_RETENTION PREFERRED_BACKUP_WINDOW PREFERRED_MAINTENANCE_WINDOW IAM_AUTH CLOUDWATCH_LOGS_EXPORTS DELETION_PROTECTION PUBLICLY_ACCESSIBLE ENABLE_PERFORMANCE_INSIGHTS PERFORMANCE_INSIGHTS_RETENTION AURORA_INSTANCE_COUNT TAGS SNAPSHOT_IDENTIFIER SOURCE_DB_IDENTIFIER AURORA_STORAGE_TYPE MANAGE_MASTER_PASSWORD; do
        # ヘッダー行と空行をスキップ
        if [ "$(echo "$REGION" | xargs)" = "REGION" ]; then continue; fi
        if [ -z "$(echo "$REGION" | xargs)" ] && [ -z "$(echo "$DB_IDENTIFIER" | xargs)" ]; then continue; fi

        log "--- ${DB_IDENTIFIER} の処理開始 ---"

        # 各変数の前後の空白を削除
        REGION=$(echo "$REGION" | xargs)
        DB_IDENTIFIER=$(echo "$DB_IDENTIFIER" | xargs)
        ENGINE=$(echo "$ENGINE" | xargs)
        ENGINE_VERSION=$(echo "$ENGINE_VERSION" | xargs)
        DB_INSTANCE_CLASS=$(echo "$DB_INSTANCE_CLASS" | xargs)
        CLUSTER_PARAMETER_GROUP=$(echo "$CLUSTER_PARAMETER_GROUP" | xargs)
        INSTANCE_PARAMETER_GROUP=$(echo "$INSTANCE_PARAMETER_GROUP" | xargs)
        SECURITY_GROUPS=$(echo "$SECURITY_GROUPS" | xargs)
        DB_SUBNET_GROUP=$(echo "$DB_SUBNET_GROUP" | xargs)
        MASTER_USERNAME=$(echo "$MASTER_USERNAME" | xargs)
        MASTER_PASSWORD=$(echo "$MASTER_PASSWORD" | xargs)
        DB_NAME=$(echo "$DB_NAME" | xargs)
        BACKUP_RETENTION=$(echo "$BACKUP_RETENTION" | xargs)
        PREFERRED_BACKUP_WINDOW=$(echo "$PREFERRED_BACKUP_WINDOW" | xargs)
        PREFERRED_MAINTENANCE_WINDOW=$(echo "$PREFERRED_MAINTENANCE_WINDOW" | xargs)
        IAM_AUTH=$(echo "$IAM_AUTH" | xargs)
        CLOUDWATCH_LOGS_EXPORTS=$(echo "$CLOUDWATCH_LOGS_EXPORTS" | xargs)
        DELETION_PROTECTION=$(echo "$DELETION_PROTECTION" | xargs)
        PUBLICLY_ACCESSIBLE=$(echo "$PUBLICLY_ACCESSIBLE" | xargs)
        ENABLE_PERFORMANCE_INSIGHTS=$(echo "$ENABLE_PERFORMANCE_INSIGHTS" | xargs)
        PERFORMANCE_INSIGHTS_RETENTION=$(echo "$PERFORMANCE_INSIGHTS_RETENTION" | xargs)
        AURORA_INSTANCE_COUNT=$(echo "$AURORA_INSTANCE_COUNT" | xargs)
        TAGS=$(echo "$TAGS" | xargs)
        SNAPSHOT_IDENTIFIER=$(echo "$SNAPSHOT_IDENTIFIER" | xargs)
        SOURCE_DB_IDENTIFIER=$(echo "$SOURCE_DB_IDENTIFIER" | xargs)
        AURORA_STORAGE_TYPE=$(echo "$AURORA_STORAGE_TYPE" | xargs)
        MANAGE_MASTER_PASSWORD=$(echo "$MANAGE_MASTER_PASSWORD" | xargs)


        # 必須項目チェック
        if [ -z "$DB_IDENTIFIER" ] || [ -z "$REGION" ] || [ -z "$ENGINE" ]; then
             log "エラー: ${DB_IDENTIFIER} 設定行に必須パラメータ (REGION, DB_IDENTIFIER, ENGINE) の不足または無効な値があります。この行はスキップします。"
             continue
        fi

        # 復元タイプと新規作成の組み合わせチェック
        if [ -n "$SNAPSHOT_IDENTIFIER" ] && [ -n "$SOURCE_DB_IDENTIFIER" ]; then
             log "エラー: ${DB_IDENTIFIER} 設定行で SNAPSHOT_IDENTIFIER と SOURCE_DB_IDENTIFIER の両方が指定されています。どちらか一方のみを指定してください。この行はスキップします 。"
             continue
        fi

        # 新規作成時の必須パラメータ検証
        if [ -z "$SNAPSHOT_IDENTIFIER" ] && [ -z "$SOURCE_DB_IDENTIFIER" ]; then
             # 認証情報検証
             if [ -z "$MANAGE_MASTER_PASSWORD" ] && ( [ -z "$MASTER_USERNAME" ] || [ -z "$MASTER_PASSWORD" ] ); then
                  log "エラー: ${DB_IDENTIFIER} 設定行で新規作成のための Secrets Manager または マスターユーザー名/マスターパスワード ペアが指定されていません。この行はスキップ します。"
                  continue
             fi
             # DB Subnet Groupが必須
             if [ -z "$DB_SUBNET_GROUP" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で DB_SUBNET_GROUP が指定されていません。新規作成時には必須です。この行はスキップします。"
               continue
             fi
              # EngineVersionが必須
             if [ -z "$ENGINE_VERSION" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で ENGINE_VERSION が指定されていません。新規作成時には必須です。"
               continue
             fi
        else # 復元系の場合の必須パラメータ検証
             # DB Subnet Groupが必須
             if [ -z "$DB_SUBNET_GROUP" ]; then
               log "エラー: ${DB_IDENTIFIER} 設定行で DB_SUBNET_GROUP が指定されていません。復元時には必須です。この行はスキップします。"
               continue
             fi
        fi

        # AURORA_INSTANCE_COUNT の数値評価とバリデーション
        local aurora_instance_count_num=0
        local is_valid_instance_count=true # 無効な値の場合はインスタンス管理/作成をスキップするためのフラグ

        if [ -n "$AURORA_INSTANCE_COUNT" ]; then
            if [[ "$AURORA_INSTANCE_COUNT" =~ ^[0-9]+$ ]]; then # 非負の整数形式かチェック
                aurora_instance_count_num=$AURORA_INSTANCE_COUNT
            else
                log "警告: ${DB_IDENTIFIER}: AURORA_INSTANCE_COUNT '$AURORA_INSTANCE_COUNT' が無効な値です（非負の整数を指定してください）。この行のインスタンス管理/作成はスキップします。"
                is_valid_instance_count=false # 無効な値なのでフラグを立てる
            fi
        else
             # AURORA_INSTANCE_COUNT が空の場合はデフォルトの1として扱う
             aurora_instance_count_num=1
        fi

        # AURORA_INSTANCE_COUNT が有効な値 (>=0) である場合のみ、DB_INSTANCE_CLASS の必須チェックを行う
        # インスタンス総数が1以上の場合、DB_INSTANCE_CLASSが必須
        if [ "$is_valid_instance_count" = true ] && [ "$aurora_instance_count_num" -ge 1 ] && [ -z "$DB_INSTANCE_CLASS" ]; then
            log "エラー: ${DB_IDENTIFIER} 設定行で AURORA_INSTANCE_COUNT ($AURORA_INSTANCE_COUNT) >= 1 ですが DB_INSTANCE_CLASS が指定されていません。インスタンス作成/管理には必須です。この行はスキップします。"
            continue # この行の処理を中断し、次のCSV行へ進む
        fi
        
        # AURORA_INSTANCE_COUNT が無効な値だった場合は、この行のインスタンス管理/作成をスキップ
        if [ "$is_valid_instance_count" = false ]; then
             log "--- ${DB_IDENTIFIER} の処理完了 (無効なインスタンス数) ---"
             continue # この行の処理を中断し、次のCSV行へ進む
        fi


        # クラスターの存在をチェック
        local cluster_status=$(check_cluster_exists "$DB_IDENTIFIER" "$REGION")

        if [ -n "$cluster_status" ]; then # ステータスが取得できれば存在する
            log "クラスター ${DB_IDENTIFIER} は既に存在します (状態: ${cluster_status})。"
            # 存在するクラスターに対してはパラメータ更新とインスタンス管理を行う

            # パラメータ更新を実行
            if update_aurora_cluster; then
                # AURORA_INSTANCE_COUNT が有効な値 (>=0) の場合のみインスタンス管理を実行
                # manage_aurora_instances は 目標総数 >= 0 を期待して呼ばれる
                manage_aurora_instances # 既存クラスターのインスタンス管理関数を呼び出し
            else
                 log "${DB_IDENTIFIER} のクラスターパラメータ更新コマンド発行が失敗したため、インスタンス管理をスキップします。"
            fi

        else # クラスターが存在しない
            log "クラスター ${DB_IDENTIFIER} は存在しません。新規作成または復元を開始します。"
            # create_aurora_cluster 関数は内部で新規作成/復元を判定しコマンドを発行
            if create_aurora_cluster; then
                # 新規作成パスの場合のみインスタンスの初期作成コマンドを発行
                # スナップショット/PITR復元の場合、インスタンスは復元処理の一部として作成されるため、ここでは manage_aurora_create_instances を呼ばない
                if [ -z "$SNAPSHOT_IDENTIFIER" ] && [ -z "$SOURCE_DB_IDENTIFIER" ]; then
                    log "${DB_IDENTIFIER}: 新規作成コマンド発行が成功しました。インスタンスの初期作成コマンドを発行します。"
                     # manage_aurora_create_instances は目標総数 >= 1 を期待して呼ばれる
                     if [ "$aurora_instance_count_num" -ge 1 ]; then
                        manage_aurora_create_instances # 新規作成時のインスタンス作成関数を呼び出し
                     else
                       log "${DB_IDENTIFIER}: AURORA_INSTANCE_COUNT が 0 のため、新規インスタンス作成は行いません（プライマリなし）。"
                     fi
                else
                     log "${DB_IDENTIFIER}: 復元コマンド発行が成功しました。インスタンスは復元処理の一部として作成されるか、別途手動/スクリプト実行後に管理してください。"
                fi
            else
                 log "${DB_IDENTIFIER} のクラスター作成/復元コマンド発行が失敗したため、インスタンス関連処理をスキップします。"
            fi
        fi

        log "--- ${DB_IDENTIFIER} の処理完了 ---"
    done < <(tail -n +2 "$CONFIG_CSV") # ヘッダー行をスキップしてwhileループに渡す

    log "CSVファイルのすべてのエントリの処理が完了しました。"
}

# スクリプト実行時にmain関数を呼び出し、コマンドライン引数を渡す
main "$@"
