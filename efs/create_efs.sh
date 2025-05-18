#!/bin/bash
# CSVファイルからAWS EFSファイルシステムを作成/削除するスクリプト

# スクリプト実行時のエラーを捕捉し、パイプライン中のエラーも検出して即座に終了する (今回はエラーハンドリングを明示的に行うためコメントアウト)
# set -euo pipefail

# sed コマンドを使った前後の空白トリム関数 (引用符に影響されにくい)
trim_whitespace() {
echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

# ログ出力関数
log() {
local level="$1" # INFO, WARN, ERROR
local message="$2"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [EFS_SCRIPT] [$level] $message"
}

# エラーメッセージを出力して終了する関数 (全体スクリプト中断時のみ使用)
error_exit() {
log "ERROR" "$1" >&2
exit 1
}


# --- ヘルパー関数 ---

# サブネット名またはIDをサブネットIDに解決する関数
# 戻り値: 0:成功(IDをecho), 1:失敗(ERRORログをstderr)
# 引数1: AWSリージョン
# 引数2: サブネット名またはID
resolve_subnet_id() {
local region="$1"
local name_or_id="$2"
local subnet_id=""

# まずIDとして解決を試みる
subnet_id=$(aws ec2 describe-subnets \
 --region "$region" \
 --filters "Name=subnet-id,Values=$name_or_id" \
 --query 'Subnets[0].SubnetId' \
 --output text 2>/dev/null)

# IDで見つからなかった場合、Nameタグとして解決を試みる
if [ -z "$subnet_id" ] || [ "$subnet_id" == "None" ]; then
 subnet_id=$(aws ec2 describe-subnets \
 --region "$region" \
 --filters "Name=tag:Name,Values=$name_or_id" \
 --query 'Subnets[0].SubnetId' \
 --output text 2>/dev/null)
fi

if [ -z "$subnet_id" ] || [ "$subnet_id" == "None" ]; then
 log "ERROR" "リージョン '$region' でサブネット '$name_or_id' が見つかりませんでした。" >&2
 return 1 # 失敗を示す
else
 echo "$subnet_id" # 解決したIDを出力
 return 0
fi
}

# セキュリティグループ名またはIDをセキュリティグループIDに解決する関数
# 戻り値: 0:成功(IDをecho), 1:失敗(ERRORログをstderr)
# 引数1: AWSリージョン
# 引数2: セキュリティグループ名またはID
resolve_security_group_id() {
local region="$1"
local name_or_id="$2"
local sg_id=""

# まずIDとして解決を試みる
sg_id=$(aws ec2 describe-security-groups \
 --region "$region" \
 --filters "Name=group-id,Values=$name_or_id" \
 --query 'SecurityGroups[0].GroupId' \
 --output text 2>/dev/null)

# IDで見つからなかった場合、group-nameとして解決を試みる
if [ -z "$sg_id" ] || [ "$sg_id" == "None" ]; then
 sg_id=$(aws ec2 describe-security-groups \
 --region "$region" \
 --filters "Name=group-name,Values=$name_or_id" \
 --query 'SecurityGroups[0].GroupId' \
 --output text 2>/dev/null)
fi

if [ -z "$sg_id" ] || [ "$sg_id" == "None" ]; then
 log "ERROR" "リージョン '$region' でセキュリティグループ '$name_or_id' が見つかりませんでした。" >&2
 return 1 # 失敗を示す
else
 echo "$sg_id" # 解決したIDを出力
 return 0
fi
}

# EFSファイルシステムを名前で検索し、IDを返す関数
# 戻り値:
# 0: EFSが見つかった (IDが標準出力される)
# 1: EFSが見つからなかった (INFOログが標準エラー出力される)
# 2: AWS CLIコマンド実行中にエラーが発生した (エラーログが標準エラー出力される)
# 引数1: AWSリージョン
# 引数2: EFSファイルシステム名 (Nameタグ)
get_efs_id_by_name() {
local region="$1"
local efs_name="$2"
local aws_output # 標準出力と標準エラー出力両方を一時的に格納
local aws_exit_code

# describe-file-systems を実行し、出力と終了コードを同時に取得
# --filters は EFS では無効なので削除済み
aws_output=$(aws efs describe-file-systems \
 --region "$region" \
 --query "FileSystems[?Tags[?Key=='Name'&&Value=='$efs_name']].FileSystemId" \
 --output text 2>&1) # 標準エラー出力もキャプチャ
aws_exit_code=$?

# AWS CLIコマンド自体がエラーの場合 (終了コード != 0 または出力にエラー/Exceptionが含まれる)
# describeで見つからない場合も終了コード0を返すが、NotFoundExceptionというエラーメッセージをstderrに出す場合がある
if [ $aws_exit_code -ne 0 ] || echo "$aws_output" | grep -q 'ERROR\|Exception'; then
 # ただし、NotFoundException は EFS が見つからなかったことを意味するので、それはエラーとは見なさない
 if ! echo "$aws_output" | grep -q 'NotFoundException'; then
 log "ERROR" "EFSファイルシステム '$efs_name' (リージョン $region) の検索中にAWS CLIエラーが発生しました: $aws_output" >&2
 return 2 # AWS CLIエラーを示す終了コード
 fi
fi

# aws_output が "None" または空文字の場合は見つからなかった
# 見つかった場合は FileSystemId が入っている
local fs_id=$(trim_whitespace "$aws_output") # Capture the actual output (ID or "None" or error text)

if [ -n "$fs_id" ] && [ "$fs_id" != "None" ] && ! echo "$fs_id" | grep -q 'ERROR\|Exception\|NotFoundException'; then
 # 見つかった場合 (出力があり、かつエラーメッセージではない)
 echo "$fs_id" # 見つかったIDを標準出力にecho
 return 0 # 見つかったことを示す終了コード
else
 # 見つからなかった場合 (出力が空、"None"、または NotFoundException だった)
 log "INFO" "EFSファイルシステム '$efs_name' (リージョン $region) は見つかりませんでした。" >&2 # INFOログはstderrへ
 return 1 # 見つからなかったことを示す終了コード
fi
}


# EFSファイルシステムが利用可能になるまで待機する関数
wait_for_efs_available() {
local fs_id="$1"
local region="$2"
local max_retries=60 # 10秒 * 60回 = 10分
local retry_interval=10
local retry_count=0

log "INFO" "EFS '$fs_id' が利用可能になるのを待機中..."

while [ $retry_count -lt $max_retries ]; do
 # 標準エラー出力もキャプチャしてエラーを詳細に診断できるようにする
 local describe_output=$(aws efs describe-file-systems \
   --file-system-id "$fs_id" \
   --region "$region" \
   --query "FileSystems[0].LifeCycleState" \
   --output text 2>&1) # Capture stderr here
 local exit_code=$?

 local status=""
 local error_output=""

 # 出力にエラー/Exceptionパターンが含まれるかチェック
 if echo "$describe_output" | grep -q 'ERROR\|Exception'; then
   error_output="$describe_output" # 出力全体をエラーと見なす
 else
   status=$(trim_whitespace "$describe_output") # そうでなければ、出力はステータス (または空)
 fi


 # Case 1: AWS CLIコマンドが失敗した、またはエラー出力を返した
 if [ $exit_code -ne 0 ] || [ -n "$error_output" ]; then
   # NotFoundException はファイルシステムが存在しない（待機終了）ことを意味する
   if echo "$error_output" | grep -q 'NotFoundException\|FileSystemNotFound'; then
    log "ERROR" "待機中にEFS '$fs_id' が見つからなくなりました。作成に失敗したか削除された可能性があります。処理を中断します。" >&2
    return 1 # 待機失敗と見なす
   else
    # その他のエラー: 警告としてログしてリトライ
    log "WARN" "EFS '$fs_id' の状態取得中にAWS CLIコマンドが一時的に失敗しました (終了コード: $exit_code)。出力: $describe_output。リトライします。" >&2
    # リトライカウントはここでインクリメント
   fi
 fi

 # Case 2: AWS CLIコマンドは成功したが、ステータスが利用可能ではない
 if [ "$status" == "available" ]; then
   log "INFO" "EFS '$fs_id' が利用可能になりました"
   return 0 # 成功
 fi

 # Case 3: AWS CLIコマンドは成功したが、ステータスが空、"None"、またはその他の予期しない状態
 if [ -z "$status" ] || [ "$status" == "None" ] || ([ "$status" != "creating" ] && [ "$status" != "available" ]); then
   # 状態が空、None、または creating/available 以外の予期しない状態の場合警告
   log "WARN" "EFS '$fs_id' の状態取得で予期しない結果 '${status:-unknown}' が返されました (終了コード: $exit_code)。現在の状態: $status。リトライします。" >&2
 fi


 # リトライカウントをインクリメント
 retry_count=$((retry_count + 1))
 log "INFO" "待機中... ($retry_count/$max_retries) 現在の状態: ${status:-unknown}, 終了コード: $exit_code"


 sleep $retry_interval
done

log "ERROR" "EFS '$fs_id' が利用可能になるまでにタイムアウトしました" >&2
return 1 # 失敗
}


# マウントターゲットがすべて削除されるまで待機する関数
wait_for_mount_targets_deleted() {
local fs_id="$1"
local region="$2"
local max_retries=60 # 10秒 * 60回 = 10分
local retry_interval=10
local retry_count=0

log "INFO" "EFS '$fs_id' のマウントターゲットがすべて削除されるのを待機中..."

while [ $retry_count -lt $max_retries ]; do
 # 標準エラー出力もキャプチャ
 local describe_output=$(aws efs describe-mount-targets \
   --file-system-id "$fs_id" \
   --region "$region" \
   --query "MountTargets[].MountTargetId" \
   --output text 2>&1) # Capture stderr
 local exit_code=$?

 local mt_ids=""
 local error_output=""

 if echo "$describe_output" | grep -q 'ERROR\|Exception'; then
   error_output="$describe_output"
 else
   mt_ids=$(trim_whitespace "$describe_output")
 fi

 # AWS CLIコマンドが失敗した、またはエラー出力を返した場合
 if [ $exit_code -ne 0 ] || [ -n "$error_output" ]; then
   # FileSystemNotFound または NotFoundException は、ファイルシステム自体が削除されたことを意味する
   if echo "$error_output" | grep -q 'FileSystemNotFound\|NotFoundException'; then
     log "INFO" "EFSファイルシステム '$fs_id' が見つかりません。マウントターゲットも存在しないと見なします。"
     return 0 # 成功と見なす
   else
     # その他のエラー: 警告としてログしてリトライ
     log "WARN" "EFS '$fs_id' のマウントターゲット状態取得中にAWS CLIコマンドが一時的に失敗しました (終了コード: $exit_code)。出力: $describe_output。リトライします。" >&2
     # リトライカウントはここでインクリメント
   fi
 fi

 # マウントターゲットが一つもなければ成功
 if [ -z "$mt_ids" ]; then
   log "INFO" "EFS '$fs_id' のマウントターゲットはすべて削除されました"
   return 0 # 成功
 fi


 # リトライカウントをインクリメント
 retry_count=$((retry_count + 1))
 log "INFO" "待機中... ($retry_count/$max_retries) 残っているマウントターゲット: ${mt_ids:-none}, 終了コード: $exit_code"

 sleep $retry_interval
done

log "ERROR" "EFS '$fs_id' のマウントターゲットがすべて削除されるまでにタイムアウトしました" >&2
return 1 # 失敗
}

# EFSファイルシステム自体が削除されるまで待機する関数
wait_for_efs_deleted() {
local fs_id="$1"
local region="$2"
local max_retries=60 # 10秒 * 60回 = 10分
local retry_interval=10
local retry_count=0

log "INFO" "EFSファイルシステム '$fs_id' が削除されるのを待機中..."

while [ $retry_count -lt $max_retries ]; do
 # 標準エラー出力もキャプチャしてエラーを詳細に診断できるようにする
 local describe_output=$(aws efs describe-file-systems \
   --file-system-id "$fs_id" \
   --region "$region" \
   --query "FileSystems[0].LifeCycleState" \
   --output text 2>&1) # Capture stderr here
 local exit_code=$?

 local status=""
 local error_output=""
 local trimmed_output=$(trim_whitespace "$describe_output")


 # Check for deletion success conditions FIRST
 # Case A: AWS CLI command failed OR output indicates Not Found error (regardless of exit code 0 or non-zero)
 if [ $exit_code -ne 0 ] || echo "$trimmed_output" | grep -q 'NotFoundException\|FileSystemNotFound'; then
    log "INFO" "EFSファイルシステム '$fs_id' は削除されたか、存在しません。"
    return 0 # **SUCCESS** - File is gone or never existed
 fi

 # If we reach here, the command exited with 0 and the output did NOT contain NotFound text.
 # Now check for valid states or other unexpected output.
 status="$trimmed_output" # Assume the trimmed output is the status if not an error pattern

 # Case B: Command succeeded (exit code 0) and returned a valid state
 if [ "$status" == "deleted" ]; then
    log "INFO" "EFS '$fs_id' は 'deleted' 状態になりました。"
    return 0 # **SUCCESS** - File is in deleted state
 elif [ "$status" == "deleting" ]; then
    # Correct state during deletion, just wait
    log "INFO" "EFS '$fs_id' は 'deleting' 状態です。待機中..." # More specific state logging
 elif [ -n "$status" ] && [ "$status" != "None" ]; then
    # Command succeeded (exit 0), output is not empty/None/NotFound/deleted/deleting
    # This is an unexpected state during deletion
    log "WARN" "EFS '$fs_id' が削除中に予期しないライフサイクル状態 '$status' です (終了コード: $exit_code)。" >&2
 elif [ -z "$status" ] || [ "$status" == "None" ]; then
    # Command succeeded (exit 0), but output is empty or None
    # This is also unexpected - should get a state or NotFound error if ID is valid
    log "WARN" "EFS '$fs_id' の状態取得結果が空またはNoneでした (終了コード: $exit_code)。" >&2
  # else: If exit_code was non-zero AND output did *not* contain NotFound (already handled in Case A),
  # that would be another error scenario, but Case A's first check covers exit_code != 0.
  # So Case B logic only needs to run if Case A (NotFound or non-zero exit) is false.
 fi


 # Increment retry and log wait message
 retry_count=$((retry_count + 1))
 log "INFO" "待機中... ($retry_count/$max_retries) 状態取得出力: ${describe_output}, 終了コード: $exit_code"

 sleep $retry_interval
done

log "ERROR" "EFSファイルシステム '$fs_id' が削除されるまでにタイムアウトしました" >&2
return 1 # Failure
}


# --- メインスクリプト処理 ---

# スクリプトの使い方を表示する関数 (引数チェックで使用)
usage() {
echo "使い方: $0 <csv_ファイルパス>"
exit 1
}

# CSVファイルパスが引数として提供されているか確認
if [ "$#" -ne 1 ]; then
usage
fi

CSV_FILE="$1"

# CSVファイルが存在するか確認
if [ ! -f "$CSV_FILE" ]; then
error_exit "CSVファイルが見つかりません: $CSV_FILE"
fi

log "INFO" "--- EFS管理処理を開始します ---"
log "INFO" "処理対象CSVファイル: $CSV_FILE"
echo "-------------------------------------"

# CSVファイルを1行ずつ読み込み、フィールドを配列に格納
# プロセス置換 < <(...) を使用して、変数スコープの問題を回避
# ACTION カラムが追加され、さらに PROVISIONED_THROUGHPUT_MIBPS が追加されたため、フィールド数は14になる
# read コマンドと変数割り当てを修正
tail -n +2 "$CSV_FILE" | while IFS=, read -r -a fields; do

# 期待されるフィールド数 (ACTION + PROVISIONED_THROUGHPUT_MIBPS カラム追加により14個になる)
expected_fields=14

# フィールド数が期待通りかチェック
if [ "${#fields[@]}" -ne "$expected_fields" ]; then
 log "ERROR" "CSVの行のフィールド数が期待値 ($expected_fields個) と異なります (${#fields[@]}個)。この行をスキップします。" >&2
 continue # 次のCSV行へスキップ
fi

# 配列から各変数に割り当て (配列インデックスは0から始まる)
# ここでは local は不要。whileループのサブシェル内で一時的な変数となる。
ACTION_RAW="${fields[0]:-}"
REGION_CSV="${fields[1]:-}"
EFS_NAME_RAW="${fields[2]:-}"
ENCRYPTED_RAW="${fields[3]:-}"
PERFORMANCE_MODE_RAW="${fields[4]:-}"
THROUGHPUT_MODE_RAW="${fields[5]:-}"
PROVISIONED_THROUGHPUT_MIBPS_RAW="${fields[6]:-}"
LC_TRANSITION_IA_DAYS_RAW="${fields[7]:-}"
LC_TRANSITION_ARCHIVE_DAYS_RAW="${fields[8]:-}"
LC_TRANSITION_PRIMARY_ON_ACCESS_RAW="${fields[9]:-}"
BACKUP_ENABLED_RAW="${fields[10]:-}"
SUBNETS_STR_RAW="${fields[11]:-}"
SECURITY_GROUPS_STR_RAW="${fields[12]:-}"
ACCESS_POINTS_STR_RAW="${fields[13]:-}"

# 各変数の前後の空白文字をトリム (sed 関数を使用)
# ここでも local は不要。
ACTION=$(trim_whitespace "$ACTION_RAW")
REGION=$(trim_whitespace "$REGION_CSV")
EFS_NAME=$(trim_whitespace "$EFS_NAME_RAW")
ENCRYPTED=$(trim_whitespace "$ENCRYPTED_RAW")
PERFORMANCE_MODE=$(trim_whitespace "$PERFORMANCE_MODE_RAW")
THROUGHPUT_MODE=$(trim_whitespace "$THROUGHPUT_MODE_RAW")
PROVISIONED_THROUGHPUT_MIBPS=$(trim_whitespace "$PROVISIONED_THROUGHPUT_MIBPS_RAW")
LC_TRANSITION_IA_DAYS=$(trim_whitespace "$LC_TRANSITION_IA_DAYS_RAW")
LC_TRANSITION_ARCHIVE_DAYS=$(trim_whitespace "$LC_TRANSITION_ARCHIVE_DAYS_RAW")
LC_TRANSITION_PRIMARY_ON_ACCESS=$(trim_whitespace "$LC_TRANSITION_PRIMARY_ON_ACCESS_RAW")
BACKUP_ENABLED=$(trim_whitespace "$BACKUP_ENABLED_RAW")
SUBNETS_STR=$(trim_whitespace "$SUBNETS_STR_RAW")
SECURITY_GROUPS_STR=$(trim_whitespace "$SECURITY_GROUPS_STR_RAW")
ACCESS_POINTS_STR=$(trim_whitespace "$ACCESS_POINTS_STR_RAW")


log "INFO" "--- EFSエントリを処理中: '$ACTION' on '$EFS_NAME' (リージョン: $REGION) ---"

# 必須フィールドの検証 (ACTIONを追加)
if [ -z "$ACTION" ] || [ -z "$REGION" ] || [ -z "$EFS_NAME" ]; then
 log "ERROR" "必須フィールド (ACTION, REGION, EFS_NAME) が不足しています。このエントリをスキップします。" >&2
 continue # 次のCSV行へスキップ
fi

# ACTION に応じて処理を分岐
case "$ACTION" in
 add)
 log "INFO" "アクション: 作成 (add)"

 # 作成に必要な追加フィールドの検証
 if [ -z "$PERFORMANCE_MODE" ] || [ -z "$THROUGHPUT_MODE" ]; then
  log "ERROR" "作成アクションには必須フィールド (PERFORMANCE_MODE, THROUGHPUT_MODE) が不足しています。このエントリをスキップします。" >&2
  continue
 fi

 # 有効な THROUGHPUT_MODE 値のチェック (ValidationExceptionを避けるため)
 case "$THROUGHPUT_MODE" in
  bursting|provisioned|elastic)
  # 有効な値
  ;;
  *)
  log "ERROR" "EFS '$EFS_NAME' 用の THROUGHPUT_MODE '$THROUGHPUT_MODE' は無効です。有効な値は 'bursting', 'provisioned', 'elastic' です。このエントリをスキップします。" >&2
  continue
  ;;
 esac

 # throughput-mode が provisioned の場合の、provisioned-throughput-in-mibps の検証と設定
 PROVISIONED_THROUGHPUT_ARGS=() # 追加する引数を格納する配列
 if [ "$THROUGHPUT_MODE" == "provisioned" ]; then
  if [ -z "$PROVISIONED_THROUGHPUT_MIBPS" ] || [[ ! "$PROVISIONED_THROUGHPUT_MIBPS" =~ ^[0-9]+$ ]] || [ "$PROVISIONED_THROUGHPUT_MIBPS" -lt 1 ]; then
  log "ERROR" "THROUGHPUT_MODEが 'provisioned' の場合、PROVISIONED_THROUGHPUT_MIBPS に 1以上の数値 (MiB/s) を指定する必要があります。指定された値: '$PROVISIONED_THROUGHPUT_MIBPS'。このエントリをスキップします。" >&2
  continue
  fi
  PROVISIONED_THROUGHPUT_ARGS=("--provisioned-throughput-in-mibps" "$PROVISIONED_THROUGHPUT_MIBPS")
 fi

 # --- EFSの存在チェックと処理分岐 (ロジックを修正) ---
 # get_efs_id_by_name関数は以下を返す:
 # 0: 見つかった (IDをecho)
 # 1: 見つからなかった (INFOログがstderr)
 # 2: AWS CLIエラー (エラーログがstderr)
 # ここでは local は不要
 check_result=$(get_efs_id_by_name "$REGION" "$EFS_NAME") # ID or Nothing or Error Output from stderr
 check_exit_code=$?

 if [ $check_exit_code -eq 0 ]; then
  # 終了コード0: EFSが見つかった
  # ここでも local は不要
  existing_efs_id="$check_result" # get_efs_id_by_nameがstdoutにechoしたIDを取得
  log "WARN" "EFSファイルシステム '$EFS_NAME' (リージョン $REGION) は既に存在します (ID: $existing_efs_id)。作成をスキップします。"
  continue # 次のCSV行へスキップ (作成不要のため)
 elif [ $check_exit_code -eq 2 ]; then
  # 終了コード2: AWS CLIエラーが発生した (get_efs_id_by_name内でエラーログ済み)
  log "ERROR" "既存EFSの存在チェック中にAWSエラーが発生しました。このエントリの作成をスキップします。" >&2
  continue # 次のCSV行へスキップ
 else # [ $check_exit_code -eq 1 ] の場合
  # 終了コード1: EFSが見つからなかった (get_efs_id_by_name内でINFOログ済み)
  log "INFO" "EFSファイルシステム '$EFS_NAME' は存在しません。作成を開始します。"
  # 作成処理を続行するために、ここでは continue しない
 fi
 # --- EFSの存在チェックと処理分岐終わり ---


 # --- EFSファイルシステムの作成コマンド構築 ---
 log "INFO" "EFSファイルシステム '$EFS_NAME' の作成コマンドを構築中..."

 CREATE_EFS_ARGS=(
  "efs" "create-file-system"
  "--region" "$REGION"
  "--tags" "Key=Name,Value=\"$EFS_NAME\""
  "--performance-mode" "$PERFORMANCE_MODE"
  "--throughput-mode" "$THROUGHPUT_MODE"
  "--query" "FileSystemId"
  "--output" "text"
 )

  ENCRYPTED_FLAG=""
  if [[ "$ENCRYPTED" =~ ^[TtYy1] ]]; then # true, yes, Y, 1 (大文字小文字区別なし) で始まるかチェック
    ENCRYPTED_FLAG="--encrypted"
  fi

  BACKUP_STATUS="" # 変数の初期化
  if [[ "$BACKUP_ENABLED" =~ ^[TtYy1] ]]; then # true, yes, Y, 1 (大文字小文字区別なし) で始まるかチェック
    BACKUP_STATUS="ENABLED"
  fi


 # throughput-mode が provisioned の場合のみ、 provisioned-throughput-in-mibps 引数を追加
 # PROVISIONED_THROUGHPUT_ARGS は既に検証済み
 CREATE_EFS_ARGS+=("${PROVISIONED_THROUGHPUT_ARGS[@]}")


 # 暗号化フラグを追加
 if [ -n "$ENCRYPTED_FLAG" ]; then
  CREATE_EFS_ARGS+=("$ENCRYPTED_FLAG")
 fi


 # --- EFSファイルシステムの作成実行 ---
 log "INFO" "AWS CLIコマンドを実行: aws ${CREATE_EFS_ARGS[*]}"
 # コマンド実行と終了ステータス、出力のキャプチャ
 capture_output=$(aws "${CREATE_EFS_ARGS[@]}" 2>&1)
 CREATE_EFS_EXIT_CODE=$?

 if [ $CREATE_EFS_EXIT_CODE -ne 0 ]; then
  log "ERROR" "EFS '$EFS_NAME' の作成に失敗しました (終了コード: $CREATE_EFS_EXIT_CODE)。" >&2
  log "ERROR" "AWS CLI出力:\n$capture_output" >&2
  continue # 次のCSV行へスキップ
 fi

 # コマンドが成功した場合、$capture_output には FileSystemId が含まれているはず
 # ここでも local は不要
 FILE_SYSTEM_ID=$(trim_whitespace "$capture_output")

 # 念のため、成功したはずだが FileSystemId が空になっていないか最終チェック
 if [ -z "$FILE_SYSTEM_ID" ]; then
  log "ERROR" "EFS '$EFS_NAME' の作成コマンドは成功コードを返しましたが、FileSystemId が取得できませんでした。" >&2
  log "ERROR" "AWS CLI出力:\n$capture_output" >&2
  continue # 次のCSV行へスキップ
 fi

 log "INFO" "EFSファイルシステムを作成しました。ID: '$FILE_SYSTEM_ID'"

 # EFSが利用可能になるまで待機。待機に失敗したら continue で次の行へ。
 wait_for_efs_available "$FILE_SYSTEM_ID" "$REGION" || {
  # wait_for_efs_available 内部でエラーログは出力済み
  log "ERROR" "EFS '$FILE_SYSTEM_ID' が利用可能になりませんでした。後続の設定手順が失敗する可能性があります。このエントリの処理を中断します。" >&2
  continue # 次のCSV行へスキップ
 }


 # --- Configure Lifecycle Policy ---
 # LIFECYCLE_POLICY_JSON は上で組み立て済み
 if [ -n "$LIFECYCLE_POLICY_JSON" ]; then # JSON文字列が空でなければ設定を実行
  log "INFO" "EFS '$FILE_SYSTEM_ID' のライフサイクルポリシーを設定中..."
  # 設定失敗は警告として扱い、スクリプトは続行
  aws efs put-lifecycle-configuration \
   --region "$REGION" \
   --file-system-id "$FILE_SYSTEM_ID" \
   --lifecycle-policies "$LIFECYCLE_POLICY_JSON" 2>&1 | while read -r line; do log "INFO" "put-lifecycle-configuration: $line"; done || log "WARN" "EFS '$FILE_SYSTEM_ID' のライフサイクルポリシー設定に失敗しました。" >&2
 else
  log "INFO" "ライフサイクルポリシー設定: EFS '$FILE_SYSTEM_ID' 用に指定されていません。"
 fi

 # --- Enable Automatic Backup ---
 # BACKUP_STATUS は上で判定済み ("ENABLED" or "DISABLED")
 log "INFO" "EFS '$FILE_SYSTEM_ID' のバックアップポリシー ($BACKUP_STATUS) を設定中..."
 # 設定失敗は警告として扱い、スクリプトは続行
 aws efs put-backup-policy \
  --region "$REGION" \
  --file-system-id "$FILE_SYSTEM_ID" \
  --backup-policy Status="$BACKUP_STATUS" 2>&1 | while read -r line; do log "INFO" "put-backup-policy: $line"; done || log "WARN" "EFS '$FILE_SYSTEM_ID' のバックアップポリシー設定に失敗しました。" >&2

  # --- Create Mount Targets ---
  # サブネットとセキュリティグループの文字列をセミコロンで分割
  IFS=';' read -r -a subnets_raw <<< "$SUBNETS_STR"
  IFS=';' read -r -a security_groups_raw <<< "$SECURITY_GROUPS_STR"

  # サブネットの数とセキュリティグループの数が一致するか検証
  if [ "${#subnets_raw[@]}" -ne "${#security_groups_raw[@]}" ]; then
    log "ERROR" "EFS '$EFS_NAME' 用のサブネット数 (${#subnets_raw[@]}) とセキュリティグループ数 (${#security_groups_raw[@]}) が一致しません。マウントターゲット作成をスキップします。" >&2
  else
    if [ "${#subnets_raw[@]}" -gt 0 ]; then
      log "INFO" "EFS '$FILE_SYSTEM_ID' のマウントターゲットを作成中..."
      # サブネットとセキュリティグループのペアごとに処理
      for i in "${!subnets_raw[@]}"; do
        subnet_name_or_id=$(trim_whitespace "${subnets_raw[$i]}")
        sg_name_or_id=$(trim_whitespace "${security_groups_raw[$i]}")

        log "INFO" "解決中 [$((i+1))/${#subnets_raw[@]}] サブネット: '$subnet_name_or_id', セキュリティグループ: '$sg_name_or_id'"

        # サブネットIDの解決
        resolved_subnet_id=$(resolve_subnet_id "$REGION" "$subnet_name_or_id")
        if [ $? -ne 0 ]; then
          log "ERROR" "サブネット解決失敗のため、このマウントターゲットの作成をスキップします。" >&2
          continue # このペアの処理をスキップし、次のペアへ
        fi
        log "INFO" "解決されたサブネットID: $resolved_subnet_id"

        # セキュリティグループIDの解決
        resolved_sg_id=$(resolve_security_group_id "$REGION" "$sg_name_or_id")
        if [ $? -ne 0 ]; then
          log "ERROR" "セキュリティグループ解決失敗のため、このマウントターゲットの作成をスキップします。" >&2
          continue # このペアの処理をスキップし、次のペアへ
        fi
        log "INFO" "解決されたセキュリティグループID: $resolved_sg_id"

        # マウントターゲット作成コマンド
        log "INFO" " - 作成中: サブネット $resolved_subnet_id、セキュリティグループ $resolved_sg_id"
        # 作成失敗は警告として扱い、スクリプトは続行（他のマウントターゲット処理へ）
        aws efs create-mount-target \
          --region "$REGION" \
          --file-system-id "$FILE_SYSTEM_ID" \
          --subnet-id "$resolved_subnet_id" \
          --security-groups "$resolved_sg_id" 2>&1 | while read -r line; do log "INFO" "create-mount-target ($resolved_subnet_id): $line"; done || log "WARN" "EFS '$FILE_SYSTEM_ID' のサブネット '$resolved_subnet_id' へのマウントターゲット作成に失敗しました。" >&2

        # 注意: マウントターゲットの作成には時間がかかる場合があります。ここでは明示的な待機は行いません。
        # 必要であれば、ここで wait mount-target-available を追加
      done
    else
      log "INFO" "EFS '$FILE_SYSTEM_ID' 用のマウントターゲットは指定されていません。"
    fi
  fi


  # --- Create Access Points ---
  IFS=';' read -r -a access_points_configs <<< "$ACCESS_POINTS_STR"
  if [ "${#access_points_configs[@]}" -gt 0 ]; then
   log "INFO" "EFS '$FILE_SYSTEM_ID' のアクセスポイントを作成中..."
   for ap_config in "${access_points_configs[@]}"; do
    # 設定をパスと名前に分割
    IFS='|' read -r ap_path_raw ap_name_raw <<< "$ap_config"
    ap_path=$(trim_whitespace "$ap_path_raw") # トリム
    ap_name=$(trim_whitespace "$ap_name_raw") # トリム
    if [ -n "$ap_path" ] && [ -n "$ap_name" ]; then
     log "INFO" " - 作成中: Path='$ap_path', Name='$ap_name'"
     # 作成失敗は警告として扱い、スクリプトは続行（他のアクセスポイント処理へ）
     aws efs create-access-point \
      --region "$REGION" \
      --file-system-id "$FILE_SYSTEM_ID" \
      --root-directory "Path=$ap_path" \
      --tags "Key=Name,Value=$ap_name" 2>&1 | while read -r line; do log "INFO" "create-access-point ($ap_name): $line"; done || log "WARN" "EFS '$FILE_SYSTEM_ID' 用のアクセスポイント '$ap_name' の作成に失敗しました。" >&2
    else
     # 不正なフォーマットのエントリは警告としてログ
     log "WARN" "EFS '$EFS_NAME' 用の不正なアクセスポイント設定エントリをスキップします: '$ap_config' (Path|Name 形式が必要です)" >&2
    fi
   done
  else
   log "INFO" "EFS '$FILE_SYSTEM_ID' 用のアクセスポイントは指定されていません。"
  fi

 log "INFO" "--- EFS '$EFS_NAME' (ID: $FILE_SYSTEM_ID, リージョン: $REGION) の作成および設定完了 ---"
 ;; # add アクションの終わり

 remove)
 log "INFO" "アクション: 削除 (remove)"

 # EFSファイルシステムを検索 (Nameタグで検索)
 # 削除処理では見つからない場合はスキップ、AWSエラーの場合はエラーログしてスキップ
 # ここでは local は不要
 find_fs_id=$(get_efs_id_by_name "$REGION" "$EFS_NAME") # ID or Nothing (stderr)
 find_exit_code=$?

 if [ $find_exit_code -eq 1 ]; then
  # 終了コード1: EFSが見つからなかった (get_efs_id_by_name内でINFOログ済み)
  log "WARN" "EFSファイルシステム '$EFS_NAME' (リージョン $REGION) は見つかりませんでした。削除をスキップします。"
  continue # 次のCSV行へスキップ
 elif [ $find_exit_code -eq 2 ]; then
  # 終了コード2: AWS CLIエラー (get_efs_id_by_name内でエラーログ済み)
  log "ERROR" "EFSファイルシステム '$EFS_NAME' の検索中にAWSエラーが発生しました。削除をスキップします。" >&2
  continue # 次のCSV行へスキップ
 fi

 # 終了コード0の場合、EFSが見つかった
 # find_fs_id には get_efs_id_by_name が stdout に echo した ID が入っているはず
 # ここでも local は不要
 FILE_SYSTEM_ID="$find_fs_id" # 見つかったIDを使用

 # IDが空ではないことを再確認 (念のため)
 if [ -z "$FILE_SYSTEM_ID" ]; then
  log "ERROR" "EFSファイルシステム '$EFS_NAME' の検索は成功しましたが、IDが取得できませんでした。削除をスキップします。" >&2
  continue # 次のCSV行へスキップ
 fi


 log "INFO" "EFSファイルシステム '$EFS_NAME' (ID: $FILE_SYSTEM_ID, リージョン: $REGION) を削除します。"

 # --- Delete Mount Targets ---
 # マウントターゲットを列挙
 # マウントターゲット列挙の aws コマンドが失敗した場合もチェックを追加
 MT_IDS=$(aws efs describe-mount-targets \
  --region "$REGION" \
  --file-system-id "$FILE_SYSTEM_ID" \
  --query "MountTargets[].MountTargetId" \
  --output text 2>&1) # Capture stderr
 local describe_mt_exit_code=$?

 # aws describe-mount-targets コマンド自体が失敗した場合
 if [ $describe_mt_exit_code -ne 0 ] || echo "$MT_IDS" | grep -q 'ERROR\|Exception'; then
  # ファイルシステムが既に削除されているNotFoundExceptionの場合はエラーとしない
  if ! echo "$MT_IDS" | grep -q 'FileSystemNotFound\|NotFoundException'; then
  log "ERROR" "EFS '$FILE_SYSTEM_ID' のマウントターゲット列挙に失敗しました: $MT_IDS。ファイルシステム削除をスキップします。" >&2
  continue # 次のCSV行へスキップ
  else
  # ファイルシステムが見つからないエラーはマウントターゲットも当然ないとして処理を続行
  log "WARN" "EFSファイルシステム '$FILE_SYSTEM_ID' が見つかりませんでした（既に削除されている可能性）。マウントターゲットの削除は不要です。" >&2
  MT_IDS="" # マウントターゲットは無いと見なす
  fi
 fi

 # MT_IDS が空でない場合のみ処理を続行
 if [ -n "$(trim_whitespace "$MT_IDS")" ]; then # MT_IDS自体にエラーメッセージが入っている可能性もあるためトリムしてチェック
  # スペース区切りでIDをループ処理
  log "INFO" "EFS '$FILE_SYSTEM_ID' に関連付けられたマウントターゲットを削除中..."
  for MT_ID in $(echo "$MT_IDS" | xargs); do # xargs で不要な空白を除去しつつループ
  log "INFO" " - マウントターゲット '$MT_ID' を削除中..."
  # 削除コマンドの実行。失敗しても続行し、後で待機でチェック
  aws efs delete-mount-target \
   --region "$REGION" \
   --mount-target-id "$MT_ID" 2>&1 | while read -r line; do log "INFO" "delete-mount-target ($MT_ID): $line"; done || log "WARN" "マウントターゲット '$MT_ID' の削除コマンド発行に失敗しました。" >&2
  done

  # 全てのマウントターゲット削除コマンド発行後、EFS IDを指定してすべて削除されるのを待機
  wait_for_mount_targets_deleted "$FILE_SYSTEM_ID" "$REGION" || {
  # wait_for_mount_targets_deleted 内部でエラーログは出力済み
  log "ERROR" "EFS '$FILE_SYSTEM_ID' のマウントターゲットの削除完了待機に失敗しました。ファイルシステム削除をスキップします。" >&2
  continue # 次のCSV行へスキップ
  }

 else
  log "INFO" "EFS '$FILE_SYSTEM_ID' に関連付けられたマウントターゲットは見つかりませんでした。"
 fi

 # --- Delete File System ---
 log "INFO" "EFSファイルシステム '$FILE_SYSTEM_ID' 自体を削除中..."
 aws efs delete-file-system \
  --region "$REGION" \
  --file-system-id "$FILE_SYSTEM_ID" 2>&1 | while read -r line; do log "INFO" "delete-file-system: $line"; done || {
  log "ERROR" "EFSファイルシステム '$FILE_SYSTEM_ID' の削除コマンド発行に失敗しました。" >&2
  continue # 次のCSV行へスキップ
 }

 # ファイルシステムが削除されるまで待機
 wait_for_efs_deleted "$FILE_SYSTEM_ID" "$REGION" || {
  # wait_for_efs_deleted 内部でエラーログは出力済み
  log "ERROR" "EFSファイルシステム '$FILE_SYSTEM_ID' の削除完了待機に失敗しました。" >&2
  continue # 次のCSV行へスキップ
 }

 log "INFO" "--- EFS '$EFS_NAME' (ID: $FILE_SYSTEM_ID, リージョン: $REGION) の削除完了 ---"
 ;; # remove アクションの終わり

 *)
 # 無効なACTION
 log "ERROR" "無効なACTION '$ACTION' が指定されました。'add' または 'remove' を使用してください。このエントリをスキップします。" >&2
 continue # 次のCSV行へスキップ
 ;;
esac

done < <(tail -n +2 "$CSV_FILE")

log "INFO" "--- EFS管理処理が完了しました ---"
