#!/bin/bash

# エラー発生時にスクリプトを即座に終了する
set -e

# 📌 必須引数: RDS設定CSVファイル
if [ "$#" -ne 1 ]; then
  echo "エラー: RDS設定CSVファイルパスを指定してください。" >&2
  echo "使い方: $0 <RDS設定CSVファイルパス>" >&2
  exit 1
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
  echo "エラー: 指定されたCSVファイルが見つかりません: $CSV_FILE" >&2
  exit 1
fi

# 関数定義

# CloudWatch Logsグループの作成
create_log_group() {
  local REGION=$1
  # RDSで利用されうる各種ログタイプのロググループを作成（既に存在すればエラーになるが無視する）
  for log_type in general error slowquery audit postgresql upgrade agent; do
    aws logs create-log-group --region "$REGION" --log-group-name "/aws/rds/$log_type" 2>/dev/null || true
  done
}

# RDS拡張モニタリング用IAMロールの作成
create_monitoring_role() {
  local REGION=$1
  ROLE_NAME="rds-monitoring-role"
  if ! aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "➡️ [$REGION] 拡張モニタリング用IAMロール '$ROLE_NAME' を作成中..."
    aws iam create-role \
      --region "$REGION" \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file://<(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Service": "monitoring.rds.amazonaws.com"
    },
    "Action": "sts:AssumeRole"
  }]
}
EOF
) >/dev/null
    aws iam attach-role-policy \
      --region "$REGION" \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole >/dev/null
    echo "✅ [$REGION] 拡張モニタリング用IAMロール '$ROLE_NAME' の作成完了"
  fi
}

# セキュリティグループ名またはIDをIDリストに変換
resolve_security_groups() {
  local REGION="$1"
  local INPUT="$2"
  local -a SG_IDS=()
  IFS=';' read -ra SG_LIST <<< "$INPUT"
  for sg in "${SG_LIST[@]}"; do
    if [[ $sg == sg-* ]]; then
      SG_IDS+=("$sg")
    else
      sg_id=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters Name=group-name,Values="$sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)
      if [[ $sg_id == "None" || -z $sg_id ]]; then
        echo "❌ [$REGION] セキュリティグループ '$sg' が見つかりません" >&2
        exit 1
      fi
      SG_IDS+=("$sg_id")
    fi
  done
  echo "${SG_IDS[@]}"
}

# パスワードを取得する関数
get_password() {
  local REGION="$1"
  local PASSWORD_SOURCE="$2"
  local PASSWORD_VALUE="$3"

  case "$PASSWORD_SOURCE" in
    "secret")
      echo "⚙️ [$REGION] シークレット '$PASSWORD_VALUE' からパスワードを取得中..." >&2
      local password
      password=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$PASSWORD_VALUE" \
        --query SecretString --output text --cli-binary-format raw-in-base64-out | jq -r .password)
      
      if [ -z "$password" ]; then
          echo "❌ [$REGION] シークレット '$PASSWORD_VALUE' からパスワードを取得できませんでした" >&2
          exit 1
      fi
      echo "$password"
      ;;
    "manual")
      echo "$PASSWORD_VALUE"
      ;;
    *)
      echo "❌ [$REGION] 無効なパスワードソース '$PASSWORD_SOURCE'" >&2
      exit 1
      ;;
  esac
}

# RDSインスタンスの作成
create_rds_instance() {
  local row="$1"
  IFS=',' read -r REGION DB_IDENTIFIER ENGINE ENGINE_VERSION INSTANCE_CLASS STORAGE_TYPE ALLOCATED_STORAGE \
    MAX_ALLOCATED_STORAGE DB_NAME USERNAME PASSWORD_SOURCE PASSWORD_VALUE VPC_SG_IDS SUBNET_GROUP PARAM_GROUP \
    OPT_GROUP PUBLIC_ACCESS MONITORING_INTERVAL BACKUP_RETENTION BACKUP_WINDOW \
    MAINTENANCE_WINDOW PERFORMANCE_RETENTION TAGS MULTI_AZ LOG_EXPORTS <<< "$row"

  # パスワードを取得
  local password
  password=$(get_password "$REGION" "$PASSWORD_SOURCE" "$PASSWORD_VALUE")

  # タグ処理
  IFS=';' read -ra tag_array <<< "$TAGS"
  tag_args=()
  for tag in "${tag_array[@]}"; do
    key=$(echo "$tag" | cut -d= -f1)
    value=$(echo "$tag" | cut -d= -f2)
    if [ -n "$key" ]; then
        tag_args+=(Key="$key",Value="$value")
    fi
  done

  # アカウントIDを取得
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text)
  local monitoring_role_arn="arn:aws:iam::${account_id}:role/rds-monitoring-role"

  # セキュリティグループを解決
  echo "⚙️ [$REGION] セキュリティグループを解決中..." >&2
  local RESOLVED_SG_IDS
  RESOLVED_SG_IDS=$(resolve_security_groups "$REGION" "$VPC_SG_IDS")
  echo "✅ [$REGION] セキュリティグループID: $RESOLVED_SG_IDS" >&2

  # Multi-AZ 設定
  local multi_az_param=""
  case "${MULTI_AZ,,}" in
      "true" )
          multi_az_param="--multi-az"
          echo "ℹ️ [$REGION] Multi-AZ を有効にします" >&2
          ;;
      "false" )
          multi_az_param="--no-multi-az"
          ;;
      *)
          echo "❌ [$REGION] 無効なMULTI_AZ値 '${MULTI_AZ}'" >&2
          exit 1
          ;;
  esac

  # ログエクスポート設定
  local log_export_params=()
  if [ -n "$LOG_EXPORTS" ]; then
    IFS=';' read -ra log_types_array <<< "$LOG_EXPORTS"
    
    # エンジンごとに許可されるログタイプを定義
    local allowed_log_types=()
    case "${ENGINE,,}" in
        "mariadb")
            allowed_log_types=("error" "general" "slowquery")
            ;;
        "mysql")
            allowed_log_types=("error" "general" "slowquery" "audit")
            ;;
        "postgres")
            allowed_log_types=("postgresql" "upgrade")
            ;;
        *)
            allowed_log_types=()
            ;;
    esac

    # 許可されたログタイプのみを選択
    local filtered_logs=()
    for log_type in "${log_types_array[@]}"; do
        if [[ " ${allowed_log_types[@]} " =~ " ${log_type} " ]]; then
            filtered_logs+=("$log_type")
        else
            echo "⚠️ [$REGION] 警告: エンジン $ENGINE ではログタイプ '$log_type' はサポートされていません" >&2
        fi
    done

    if [ ${#filtered_logs[@]} -gt 0 ]; then
        log_export_params+=(--enable-cloudwatch-logs-exports "${filtered_logs[@]}")
        echo "ℹ️ [$REGION] 有効なログエクスポート: ${filtered_logs[@]}" >&2
    fi
  fi

  # 公開アクセス設定
  local publicly_accessible_param=""
  [[ "${PUBLIC_ACCESS,,}" == "true" ]] && publicly_accessible_param="--publicly-accessible" || publicly_accessible_param="--no-publicly-accessible"

  echo "🚀 [$REGION] RDSインスタンス '$DB_IDENTIFIER' を作成中..." >&2

  # RDSインスタンス作成コマンド
  aws rds create-db-instance \
    --region "$REGION" \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --db-instance-class "$INSTANCE_CLASS" \
    --engine "$ENGINE" \
    --engine-version "$ENGINE_VERSION" \
    --master-username "$USERNAME" \
    --master-user-password "$password" \
    --allocated-storage "$ALLOCATED_STORAGE" \
    --storage-type "$STORAGE_TYPE" \
    --max-allocated-storage "$MAX_ALLOCATED_STORAGE" \
    --storage-encrypted \
    "${log_export_params[@]}" \
    --auto-minor-version-upgrade \
    --vpc-security-group-ids $RESOLVED_SG_IDS \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --db-name "$DB_NAME" \
    --db-parameter-group-name "$PARAM_GROUP" \
    --option-group-name "$OPT_GROUP" \
    $publicly_accessible_param \
    --enable-performance-insights \
    --performance-insights-retention-period "$PERFORMANCE_RETENTION" \
    --monitoring-interval "$MONITORING_INTERVAL" \
    --monitoring-role-arn "$monitoring_role_arn" \
    --backup-retention-period "$BACKUP_RETENTION" \
    --preferred-backup-window "$BACKUP_WINDOW" \
    --preferred-maintenance-window "$MAINTENANCE_WINDOW" \
    --deletion-protection \
    --tags "${tag_args[@]}" \
    $multi_az_param \
    --no-cli-pager

  echo "✅ [$REGION] RDSインスタンス '$DB_IDENTIFIER' の作成コマンドを実行しました" >&2
}

# メイン処理
echo "=== RDSインスタンス作成処理を開始します ==="

tail -n +2 "$CSV_FILE" | while IFS=',' read -r -a row_array; do
  IFS=',' eval 'line="${row_array[*]}"'

  if [[ -z "$line" || "$line" =~ ^# ]]; then
    continue
  fi

  REGION=$(echo "$line" | cut -d',' -f1)
  if [ -z "$REGION" ]; then
      echo "⚠️ 無効な行をスキップ: $line" >&2
      continue
  fi

  DB_IDENTIFIER=$(echo "$line" | cut -d',' -f2)
  echo "" >&2
  echo "--- [$REGION] 処理開始: $DB_IDENTIFIER ---" >&2

  create_log_group "$REGION"
  create_monitoring_role "$REGION"
  create_rds_instance "$line"

  echo "--- [$REGION] 処理完了 ---" >&2
done

echo "" >&2
echo "=== 全てのRDS作成コマンドが完了しました ===" >&2
echo "⚠️ プロビジョニングには時間がかかります。AWSコンソールで状態を確認してください" >&2
