#!/bin/bash
# CSVファイルからAWS EFSファイルシステムを作成するスクリプト

# スクリプト実行時のエラーを捕捉し、パイプライン中のエラーも検出して即座に終了する
# set -euo pipefail

# sed コマンドを使った前後の空白トリム関数 (引用符に影響されにくい)
trim_whitespace() {
    echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}


# --- ヘルパー関数 ---

# サブネット名またはIDをサブネットIDに解決する関数
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
        echo "エラー: リージョン '$region' でサブネット '$name_or_id' が見つかりませんでした。" >&2
        return 1 # 失敗を示す
    else
        echo "$subnet_id" # 解決したIDを出力
        return 0
    fi
}

# セキュリティグループ名またはIDをセキュリティグループIDに解決する関数
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
        echo "エラー: リージョン '$region' でセキュリティグループ '$name_or_id' が見つかりませんでした。" >&2
        return 1 # 失敗を示す
    else
        echo "$sg_id" # 解決したIDを出力
        return 0
    fi
}

wait_for_efs_available() {
    local fs_id="$1"
    local region="$2"
    local max_retries=30
    local retry_interval=10
    local retry_count=0

    echo "EFS '$fs_id' が利用可能になるのを待機中..."

    while [ $retry_count -lt $max_retries ]; do
        # describe-file-systems コマンドの出力キャプチャ。
        # コマンド自体が一時的に失敗しても set -e で終了しないよう || true を追加
        local status=$(aws efs describe-file-systems \
            --file-system-id "$fs_id" \
            --region "$region" \
            --query "FileSystems[0].LifeCycleState" \
            --output text 2>/dev/null) || true # ここに || true が必要（前回の修正）

        # Captureされた status が "None" (ファイルシステムが見つからない等) かもしれないためチェック
        if [ "$status" == "available" ]; then
            echo "EFS '$fs_id' が利用可能になりました"
            return 0 # 成功
        fi

        retry_count=$((retry_count + 1))
        # status が None や空文字列の場合は "unknown" と表示
        echo "待機中... ($retry_count/$max_retries) 現在の状態: ${status:-unknown}"

        # タイムアウトチェックはsleepの前に行う
        if [ $retry_count -ge $max_retries ]; then
             echo "エラー: EFS '$fs_id' が利用可能になるまでにタイムアウトしました" >&2
             return 1 # 失敗
        fi

        sleep $retry_interval
    done

    # この行には通常到達しないはずだが、念のため失敗を示す
    return 1
}


# --- メインスクリプト処理 ---

# スクリプトの使い方を表示する関数
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
    echo "エラー: CSVファイルが見つかりません: $CSV_FILE" >&2
    usage
fi

echo "--- EFS作成処理を開始します ---"
echo "処理対象CSVファイル: $CSV_FILE"
echo "-------------------------------------"

# CSVファイルを1行ずつ読み込み、フィールドを配列に格納
# プロセス置換 < <(...) を使用して、変数スコープの問題を回避
tail -n +2 "$CSV_FILE" | while IFS=, read -r -a fields; do

    # --- デバッグ開始 ---
    #echo "--- DEBUG: read -a コマンドが読み込んだフィールド ---"
    #if [ "${#fields[@]}" -gt 0 ]; then
    #    for i in "${!fields[@]}"; do
    #        echo "フィールド $((i+1)) (インデックス $i): '${fields[$i]:-<unset>}'"
    #    done
    #else
    #    echo "（空行または読み込み失敗）"
    #fi
    #echo "--------------------------------------------"
    # --- デバッグ終了 ---


    # 期待されるフィールド数 (ヘッダー参照)
    expected_fields=12

    # フィールド数が期待通りかチェック
    if [ "${#fields[@]}" -ne "$expected_fields" ]; then
        echo "エラー: CSVの行のフィールド数が期待値 ($expected_fields個) と異なります (${#fields[@]}個)。この行をスキップします。" >&2
        continue # 次のCSV行へスキップ
    fi

    # 配列から各変数に割り当て (配列インデックスは0から始まる)
    # ${fields[インデックス]:-} は、もしインデックスが存在しない場合（理論上は上のチェックで防げる）に空文字列を代入するための安全策
    REGION_CSV="${fields[0]:-}"
    EFS_NAME_RAW="${fields[1]:-}"
    ENCRYPTED_RAW="${fields[2]:-}"
    PERFORMANCE_MODE_RAW="${fields[3]:-}"
    THROUGHPUT_MODE_RAW="${fields[4]:-}"
    LC_TRANSITION_IA_DAYS_RAW="${fields[5]:-}"
    LC_TRANSITION_ARCHIVE_DAYS_RAW="${fields[6]:-}"
    LC_TRANSITION_PRIMARY_ON_ACCESS_RAW="${fields[7]:-}"
    BACKUP_ENABLED_RAW="${fields[8]:-}"
    SUBNETS_STR_RAW="${fields[9]:-}"
    SECURITY_GROUPS_STR_RAW="${fields[10]:-}"
    ACCESS_POINTS_STR_RAW="${fields[11]:-}"


    # 各変数の前後の空白文字をトリム (sed 関数を使用)
    REGION=$(trim_whitespace "$REGION_CSV")
    EFS_NAME=$(trim_whitespace "$EFS_NAME_RAW")
    ENCRYPTED=$(trim_whitespace "$ENCRYPTED_RAW")
    PERFORMANCE_MODE=$(trim_whitespace "$PERFORMANCE_MODE_RAW")
    THROUGHPUT_MODE=$(trim_whitespace "$THROUGHPUT_MODE_RAW")
    LC_TRANSITION_IA_DAYS=$(trim_whitespace "$LC_TRANSITION_IA_DAYS_RAW")
    LC_TRANSITION_ARCHIVE_DAYS=$(trim_whitespace "$LC_TRANSITION_ARCHIVE_DAYS_RAW")
    LC_TRANSITION_PRIMARY_ON_ACCESS=$(trim_whitespace "$LC_TRANSITION_PRIMARY_ON_ACCESS_RAW")
    BACKUP_ENABLED=$(trim_whitespace "$BACKUP_ENABLED_RAW")
    SUBNETS_STR=$(trim_whitespace "$SUBNETS_STR_RAW")
    SECURITY_GROUPS_STR=$(trim_whitespace "$SECURITY_GROUPS_STR_RAW")
    ACCESS_POINTS_STR=$(trim_whitespace "$ACCESS_POINTS_STR_RAW")


    echo "--- EFSエントリを処理中: $EFS_NAME (リージョン: $REGION) ---"

    # 必須フィールドの検証
    if [ -z "$REGION" ] || [ -z "$EFS_NAME" ] || [ -z "$PERFORMANCE_MODE" ] || [ -z "$THROUGHPUT_MODE" ]; then
        echo "エラー: 必須フィールド (REGION, EFS_NAME, PERFORMANCE_MODE, THROUGHPUT_MODE) が不足しています。このエントリをスキップします。" >&2
        continue # 次のCSV行へスキップ
    fi

    # --- パラメータの準備 ---

    # 暗号化フラグの判定
    ENCRYPTED_FLAG=""
    if [[ "$ENCRYPTED" =~ ^[TtYy1] ]]; then # true, yes, Y, 1 (大文字小文字区別なし) で始まるかチェック
        ENCRYPTED_FLAG="--encrypted"
    fi

    # ライフサイクルポリシーJSON文字列の組み立て
    LIFECYCLE_POLICIES=() # ポリシーオブジェクトを格納する配列
    # IAへの移行日数
    if [ -n "$LC_TRANSITION_IA_DAYS" ]; then
        # 数値であることを確認
        if [[ "$LC_TRANSITION_IA_DAYS" =~ ^[0-9]+$ ]]; then
            LIFECYCLE_POLICIES+=('{"TransitionToIA":"AFTER_'"$LC_TRANSITION_IA_DAYS"'_DAYS"}')
        else
            echo "警告: EFS '$EFS_NAME' 用のIA移行日数 '$LC_TRANSITION_IA_DAYS' が数値ではありません。スキップします。" >&2
        fi
    fi

    # Archiveへの移行日数
    if [ -n "$LC_TRANSITION_ARCHIVE_DAYS" ]; then
        if [[ "$LC_TRANSITION_ARCHIVE_DAYS" =~ ^[0-9]+$ ]]; then
            LIFECYCLE_POLICIES+=('{"TransitionToArchive":"AFTER_'"$LC_TRANSITION_ARCHIVE_DAYS"'_DAYS"}')
        else
            echo "警告: EFS '$EFS_NAME' 用のArchive移行日数 '$LC_TRANSITION_ARCHIVE_DAYS' が数値ではありません。スキップします。" >&2
        fi
    fi

    # Primary Storage Classへの移行 (アクセス時) - TRUE/FALSE 判定
    if [[ "$LC_TRANSITION_PRIMARY_ON_ACCESS" =~ ^[TtYy1] ]]; then # TRUE, true, Yes, yes, Y, y, 1 で始まるかチェック
        LIFECYCLE_POLICIES+=('{"TransitionToPrimaryStorageClass":"AFTER_1_ACCESS"}')
    # elseの場合は特に何も追加しない (指定がFALSEや空欄なら含めない)
    fi


    LIFECYCLE_POLICY_JSON="" # この行は修正なし
    if [ "${#LIFECYCLE_POLICIES[@]}" -gt 0 ]; then
        policies_joined=$(printf '%s,' "${LIFECYCLE_POLICIES[@]}")
        LIFECYCLE_POLICY_JSON="[${policies_joined%,}]" # この行は修正なし
        echo "組み立てられたライフサイクルポリシーJSON: $LIFECYCLE_POLICY_JSON" # この行 (253) は修正なし
    else
        echo "ライフサイクルポリシー設定: EFS '$FILE_SYSTEM_ID' 用に指定されていません。"
    fi


    # バックアップ有効/無効の判定
    BACKUP_STATUS="DISABLED"
    if [[ "$BACKUP_ENABLED" =~ ^[TtYy1] ]]; then # true, yes, Y, 1 (大文字小文字区別なし) で始まるかチェック
        BACKUP_STATUS="ENABLED"
    fi

    # サブネットとセキュリティグループの文字列をセミコロンで分割
    IFS=';' read -r -a subnets_raw <<< "$SUBNETS_STR"
    IFS=';' read -r -a security_groups_raw <<< "$SECURITY_GROUPS_STR"

    # サブネットの数とセキュリティグループの数が一致するか検証
    if [ "${#subnets_raw[@]}" -ne "${#security_groups_raw[@]}" ]; then
        echo "エラー: EFS '$EFS_NAME' 用のサブネット数 (${#subnets_raw[@]}) とセキュリティグループ数 (${#security_groups_raw[@]}) が一致しません。このエントリをスキップします。" >&2
        continue
    fi

    # サブネットとセキュリティグループのIDを解決
    resolved_subnet_ids=()
    resolved_security_group_ids=()
    all_mount_target_resolved=true

    echo "サブネット解決開始 (${#subnets_raw[@]}個)"
    for i in "${!subnets_raw[@]}"; do
        subnet_name_or_id=$(trim_whitespace "${subnets_raw[$i]}")
        echo "サブネット解決中 [$((i+1))/${#subnets_raw[@]}]: '$subnet_name_or_id'"
        
        subnet_id=$(resolve_subnet_id "$REGION" "$subnet_name_or_id") || {
            echo "サブネット解決失敗: '$subnet_name_or_id'"
            all_mount_target_resolved=false
            break
        }
        resolved_subnet_ids+=("$subnet_id")
        echo "解決されたサブネットID: $subnet_id"
    done

    if $all_mount_target_resolved; then
        echo "セキュリティグループ解決開始 (${#security_groups_raw[@]}個)"
        for i in "${!security_groups_raw[@]}"; do
            sg_name_or_id=$(trim_whitespace "${security_groups_raw[$i]}")
            echo "セキュリティグループ解決中 [$((i+1))/${#security_groups_raw[@]}]: '$sg_name_or_id'"
            
            sg_id=$(resolve_security_group_id "$REGION" "$sg_name_or_id") || {
                echo "セキュリティグループ解決失敗: '$sg_name_or_id'"
                all_mount_target_resolved=false
                break
            }
            resolved_security_group_ids+=("$sg_id")
            echo "解決されたセキュリティグループID: $sg_id"
        done
    fi

    if ! $all_mount_target_resolved; then
        echo "エラー: マウントターゲット用リソースの解決に失敗したため、EFS '$EFS_NAME' の処理をスキップします" >&2
        continue
    fi

    # --- EFSファイルシステムの作成 ---
    echo "EFSファイルシステム '$EFS_NAME' を作成中..."

    CREATE_EFS_ARGS=(
        "--region" "$REGION"
        "--tags" "Key=Name,Value=\"$EFS_NAME\""
        "--performance-mode" "$PERFORMANCE_MODE"
        "--throughput-mode" "$THROUGHPUT_MODE"
        "--query" "FileSystemId"
        "--output" "text"
    )

    if [ -n "$ENCRYPTED_FLAG" ]; then
        CREATE_EFS_ARGS+=("$ENCRYPTED_FLAG")
    fi

    # 修正箇所 (前回の修正): create-file-system の実行とエラー判定のパターンを変更
    # コマンド実行と終了ステータス、出力のキャプチャを分離し、set -e で中断されないようにする
    capture_output=$(aws efs create-file-system "${CREATE_EFS_ARGS[@]}" 2>&1)
    CREATE_EFS_EXIT_CODE=$? # コマンド実行直後の終了ステータスを CREATE_EFS_EXIT_CODE 変数に格納

    # 終了ステータスが非ゼロの場合はエラー処理を行い、次のCSV行に進む
    if [ $CREATE_EFS_EXIT_CODE -ne 0 ]; then
        echo "エラー: EFS '$EFS_NAME' の作成に失敗しました (終了コード: $CREATE_EFS_EXIT_CODE)。" >&2
        # AWS CLI の出力（エラーメッセージが含まれる可能性が高い）を表示
        echo "AWS CLI出力: $capture_output" >&2
        continue # 次のCSV行へスキップ
    fi

    # コマンドが成功した場合、$capture_output には FileSystemId が含まれているはず
    FILE_SYSTEM_ID="$capture_output"

    # 念のため、成功したはずだが FileSystemId が空になっていないか最終チェック
    if [ -z "$FILE_SYSTEM_ID" ]; then
         echo "エラー: EFS '$EFS_NAME' の作成コマンドは成功コードを返しましたが、FileSystemId が取得できませんでした。" >&2
         echo "AWS CLI出力: $capture_output" >&2
         continue # 次のCSV行へスキップ
    fi


    echo "EFS ID '$FILE_SYSTEM_ID' を作成しました。"

    # EFSが利用可能になるまで待機。待機に失敗したら continue で次の行へ。
    # wait_for_efs_available 内の aws describe... には || true が入っている前提（前回の修正）
    wait_for_efs_available "$FILE_SYSTEM_ID" "$REGION" || {
        echo "警告: EFS '$FILE_SYSTEM_ID' が利用可能になりませんでした。後続の設定手順が失敗する可能性があります。このエントリの処理を中断します。" >&2
        continue # 次のCSV行へスキップ
    }


    # --- Configure Lifecycle Policy ---
    if [ -n "$LIFECYCLE_POLICY_JSON" ]; then
        echo "EFS '$FILE_SYSTEM_ID' のライフサイクルポリシーを設定中..."
        # 設定失敗は警告として扱い、スクリプトは続行
        aws efs put-lifecycle-configuration \
            --region "$REGION" \
            --file-system-id "$FILE_SYSTEM_ID" \
            --lifecycle-policies "$LIFECYCLE_POLICY_JSON" || echo "警告: EFS '$FILE_SYSTEM_ID' のライフサイクルポリシー設定に失敗しました。" >&2
            # ↑↑↑ この行の変数名が LIFECYCLE_POLICY_JSON (LIFECYCLE) であることを**必ず確認**してください。
    else
        echo "ライフサイクルポリシー設定: EFS '$FILE_SYSTEM_ID' 用に指定されていません。"
    fi

    # --- Enable Automatic Backup ---
    echo "EFS '$FILE_SYSTEM_ID' のバックアップポリシー ($BACKUP_STATUS) を設定中..."
    # 設定失敗は警告として扱い、スクリプトは続行
    aws efs put-backup-policy \
        --region "$REGION" \
        --file-system-id "$FILE_SYSTEM_ID" \
        --backup-policy Status="$BACKUP_STATUS" || echo "警告: EFS '$FILE_SYSTEM_ID' のバックアップポリシー設定に失敗しました。" >&2

    # --- Create Mount Targets ---
    if [ "${#resolved_subnet_ids[@]}" -gt 0 ]; then
        echo "EFS '$FILE_SYSTEM_ID' のマウントターゲットを作成中..."
        for i in "${!resolved_subnet_ids[@]}"; do
            subnet_id="${resolved_subnet_ids[$i]}"
            sg_id="${resolved_security_group_ids[$i]}"
            echo " - サブネット $subnet_id、セキュリティグループ $sg_id でマウントターゲットを作成中..."
            # 作成失敗は警告として扱い、スクリプトは続行（他のマウントターゲット処理へ）
            aws efs create-mount-target \
                --region "$REGION" \
                --file-system-id "$FILE_SYSTEM_ID" \
                --subnet-id "$subnet_id" \
                --security-groups "$sg_id" || echo "警告: EFS '$FILE_SYSTEM_ID' のサブネット '$subnet_id' へのマウントターゲット作成に失敗しました。" >&2
            # 注意: マウントターゲットの作成には時間がかかる場合があります。ここでは明示的な待機は行いません。
        done
    else
        echo "EFS '$FILE_SYSTEM_ID' 用のマウントターゲットは指定されていません。"
    fi


    # --- Create Access Points ---
    IFS=';' read -r -a access_points_configs <<< "$ACCESS_POINTS_STR"
    if [ "${#access_points_configs[@]}" -gt 0 ]; then
        echo "EFS '$FILE_SYSTEM_ID' のアクセスポイントを作成中..."
        for ap_config in "${access_points_configs[@]}"; do
            # 設定をパスと名前に分割
            IFS='|' read -r ap_path_raw ap_name_raw <<< "$ap_config"
            ap_path=$(trim_whitespace "$ap_path_raw") # トリム
            ap_name=$(trim_whitespace "$ap_name_raw") # トリム
            if [ -n "$ap_path" ] && [ -n "$ap_name" ]; then
                echo " - アクセスポイントを作成中 Path='$ap_path', Name='$ap_name'..."
                # 作成失敗は警告として扱い、スクリプトは続行（他のアクセスポイント処理へ）
                aws efs create-access-point \
                    --region "$REGION" \
                    --file-system-id "$FILE_SYSTEM_ID" \
                    --root-directory "Path=$ap_path" \
                    --tags "Key=Name,Value=$ap_name" || echo "警告: EFS '$FILE_SYSTEM_ID' 用のアクセスポイント '$ap_name' の作成に失敗しました。" >&2
            else
                # 不正なフォーマットのエントリはスキップ
                echo "警告: EFS '$EFS_NAME' 用の不正なアクセスポイント設定エントリをスキップします: '$ap_config' (Path|Name 形式が必要です)" >&2
            fi
        done
    else
        echo "EFS '$FILE_SYSTEM_ID' 用のアクセスポイントは指定されていません。"
    fi


    echo "--- EFS '$EFS_NAME' (ID: $FILE_SYSTEM_ID, リージョン: $REGION) の設定完了 ---"

done < <(tail -n +2 "$CSV_FILE")

# 最後の完了メッセージの閉じ引用符を修正 (前回の修正)
echo "--- EFS作成処理が完了しました ---"

echo "-------------------------------------"
echo "スクリプト終了ステータス: $?"
echo "-------------------------------------"