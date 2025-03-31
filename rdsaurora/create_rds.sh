#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
  log "エラー: $1"
  exit 1
}

get_security_group_id() {
  local sg_name_or_id=$1
  local region=$2
  if [[ $sg_name_or_id == sg-* ]]; then
    echo "$sg_name_or_id"
  else
    aws ec2 describe-security-groups \
      --region "$region" \
      --filters "Name=group-name,Values=$sg_name_or_id" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      --no-cli-pager || error_exit "セキュリティグループの取得に失敗: $sg_name_or_id"
  fi
}

create_aurora_cluster() {
  log "${DB_IDENTIFIER} の処理を開始 (リージョン: ${REGION})"

  SECURITY_GROUP_IDS=()
  for sg in $(echo "$SECURITY_GROUPS" | tr ";" "\n"); do
    sg_id=$(get_security_group_id "$sg" "$REGION")
    SECURITY_GROUP_IDS+=("$sg_id")
  done

  if [ -n "$SNAPSHOT_IDENTIFIER" ]; then
    CMD=("aws" "rds" "restore-db-cluster-from-snapshot"
      "--region" "$REGION"
      "--db-cluster-identifier" "$DB_IDENTIFIER"
      "--snapshot-identifier" "$SNAPSHOT_IDENTIFIER"
      "--engine" "$ENGINE"
      "--engine-version" "$ENGINE_VERSION"
      "--db-subnet-group-name" "$DB_SUBNET_GROUP"
      "--no-cli-pager")
  elif [ -n "$SOURCE_DB_IDENTIFIER" ]; then
    CMD=("aws" "rds" "restore-db-cluster-to-point-in-time"
      "--region" "$REGION"
      "--db-cluster-identifier" "$DB_IDENTIFIER"
      "--db-subnet-group-name" "$DB_SUBNET_GROUP"
      "--source-db-cluster-identifier" "$SOURCE_DB_IDENTIFIER"
      "--use-latest-restorable-time"
      "--no-cli-pager")
  else
    CMD=("aws" "rds" "create-db-cluster"
      "--region" "$REGION"
      "--db-cluster-identifier" "$DB_IDENTIFIER"
      "--engine" "$ENGINE"
      "--engine-version" "$ENGINE_VERSION"
      "--master-username" "$MASTER_USERNAME"
      "--master-user-password" "$MASTER_PASSWORD"
      "--db-subnet-group-name" "$DB_SUBNET_GROUP"
      "--backup-retention-period" "$BACKUP_RETENTION"
      "--preferred-backup-window" "$PREFERRED_BACKUP_WINDOW"
      "--preferred-maintenance-window" "$PREFERRED_MAINTENANCE_WINDOW"
      "--no-cli-pager")
  fi

  [ "${#SECURITY_GROUP_IDS[@]}" -gt 0 ] && CMD+=("--vpc-security-group-ids" "$(IFS=','; echo "${SECURITY_GROUP_IDS[*]}")")
  [ -n "$CLUSTER_PARAMETER_GROUP" ] && CMD+=("--db-cluster-parameter-group-name" "$CLUSTER_PARAMETER_GROUP")
  if [ -z "$SNAPSHOT_IDENTIFIER" ] && [ -z "$SOURCE_DB_IDENTIFIER" ] && [ -n "$DB_NAME" ]; then
    CMD+=("--database-name" "$DB_NAME")
  fi
  
  log "実行コマンド: ${CMD[*]}"
  if ! "${CMD[@]}"; then
    error_exit "クラスター作成に失敗"
  fi
  
  create_aurora_instances
}

create_aurora_instances() {
  for ((i=1; i<=AURORA_INSTANCE_COUNT; i++)); do
    INSTANCE_IDENTIFIER="${DB_IDENTIFIER}-instance-${i}"
    CMD=("aws" "rds" "create-db-instance"
      "--region" "$REGION"
      "--db-instance-identifier" "$INSTANCE_IDENTIFIER"
      "--db-cluster-identifier" "$DB_IDENTIFIER"
      "--engine" "$ENGINE"
      "--db-instance-class" "$DB_INSTANCE_CLASS"
      "--no-cli-pager")

    log "インスタンス作成コマンド: ${CMD[*]}"
    if ! "${CMD[@]}"; then
      error_exit "インスタンス作成に失敗: $INSTANCE_IDENTIFIER"
    fi
    log "インスタンス作成完了: $INSTANCE_IDENTIFIER"
  done
}

main() {
  # コマンドライン引数でCSVファイル名を取得
  CONFIG_CSV="$1"

  # ファイル名が指定されていない場合、エラー終了
  if [ -z "$CONFIG_CSV" ]; then
    error_exit "設定CSVファイルを指定してください。"
  fi

  # 指定されたCSVファイルが存在しない場合、エラー終了
  if [ ! -f "$CONFIG_CSV" ]; then
    error_exit "設定CSVファイルが見つかりません: $CONFIG_CSV"
  fi

  # CSVファイルの内容を読み込んで処理
  while IFS=, read -r REGION DB_IDENTIFIER ENGINE ENGINE_VERSION DB_INSTANCE_CLASS CLUSTER_PARAMETER_GROUP INSTANCE_PARAMETER_GROUP SECURITY_GROUPS DB_SUBNET_GROUP OPTION_GROUP MASTER_USERNAME MASTER_PASSWORD DB_NAME BACKUP_RETENTION PREFERRED_BACKUP_WINDOW PREFERRED_MAINTENANCE_WINDOW IAM_AUTH CLOUDWATCH_LOGS_EXPORTS DELETION_PROTECTION PUBLICLY_ACCESSIBLE ENABLE_PERFORMANCE_INSIGHTS PERFORMANCE_INSIGHTS_RETENTION AURORA_INSTANCE_COUNT TAGS SNAPSHOT_IDENTIFIER SOURCE_DB_IDENTIFIER; do
    if [ "$REGION" = "REGION" ]; then continue; fi
    create_aurora_cluster
  done < <(tail -n +2 "$CONFIG_CSV")
}

main "$@"

