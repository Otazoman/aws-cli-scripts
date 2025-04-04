#!/bin/bash
export AWS_PAGER=""

usage() {
    echo "使用方法: $0 <CSVファイルパス>"
    exit 1
}

[ $# -ne 1 ] && usage
[ ! -f "$1" ] && echo "エラー: ファイルが見つかりません" && exit 1

validate_input() {
    local nodetype=$1 enginever=$2 at_rest_enc=$3 transit_enc=$4 cluster_mode=$5 automatic_failover=$6 numnodes=$7

    echo "=== 入力検証 ==="
    echo "ノードタイプ: $nodetype"
    echo "エンジンバージョン: $enginever"
    echo "保管中暗号化: $at_rest_enc"
    echo "転送中暗号化: $transit_enc"
    echo "クラスターモード: $cluster_mode"
    echo "自動フェイルオーバー: $automatic_failover"
    echo "ノード数: $numnodes"

    [ "$transit_enc" == "enabled" ] && [ "$at_rest_enc" != "enabled" ] && { echo "エラー: 転送中の暗号化には保管中の暗号化が必要です"; return 1; }
    [ "$automatic_failover" == "enabled" ] && [ "$cluster_mode" != "enabled" ] && { echo "エラー: マルチAZはクラスターモードでのみ利用可能です"; return 1; }

    return 0
}

get_security_group_id() {
    local region=$1 sg_identifier=$2
    [[ $sg_identifier =~ ^sg-[a-z0-9]+$ ]] && { echo "$sg_identifier"; return 0; }

    echo "セキュリティグループ名からIDを検索: $sg_identifier (リージョン: $region)" >&2
    local sg_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=$sg_identifier" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>/dev/null)

    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
        echo "エラー: セキュリティグループ '$sg_identifier' をリージョン $region で見つけられません" >&2
        return 1
    fi
    echo "セキュリティグループID: $sg_id" >&2
    echo "$sg_id"
}

check_subnet_group() {
    local region=$1 subnet_group=$2
    aws elasticache describe-cache-subnet-groups \
        --region "$region" \
        --cache-subnet-group-name "$subnet_group" &>/dev/null
    if [ $? -ne 0 ]; then
        echo "エラー: サブネットグループ $subnet_group がリージョン $region に存在しません"
        return 1
    fi
    return 0
}

parse_tags() {
    local tags_json="[" pair key value
    IFS=';' read -ra pairs <<< "$1"
    for pair in "${pairs[@]}"; do
        IFS='=' read -r key value <<< "$pair"
        tags_json+="{\"Key\":\"${key// }\",\"Value\":\"${value// }\"},"
    done
    echo "${tags_json%,}]"
}

check_snapshot_exists() {
    local region=$1 snapshot_name=$2
    aws elasticache describe-snapshots \
        --region "$region" \
        --snapshot-name "$snapshot_name" &>/dev/null
    return $?
}

process_csv() {
    local header=$(head -1 "$1")
    local expected="REGION,CLUSTERID,ENGINE,NODETYPE,NUMCACHENODES,PARAMETERGROUPNAME,ENGINEVERSION,CACHESUBNETGROUPNAME,SECURITYGROUPIDENTIFIERS,AT_REST_ENCRYPTION,CLUSTER_MODE,NUM_SHARDS,IN_TRANSIT_ENCRYPTION,MAINTENANCE_WINDOW,AUTO_UPGRADE,SNAPSHOT_ENABLED,SNAPSHOT_WINDOW,SNAPSHOT_RETENTION,AUTOMATIC_FAILOVER,TAGS,SNAPSHOT_NAME,RESTORE_MODE"

    echo "=== CSVヘッダー検証 ==="
    echo "期待するヘッダー: $expected"
    echo "実際のヘッダー: $header"

    [ "${header//[[:space:]]/}" != "${expected//[[:space:]]/}" ] && {
        echo "エラー: CSVヘッダー形式が一致しません"
        return 1
    }

    echo "=== クラスター作成/復元開始 ==="
    local line_num=1
    while IFS=, read -r line || [ -n "$line" ]; do
        line_num=$((line_num+1))
        [ $line_num -eq 2 ] && continue

        echo "--- 行 $line_num 処理中 ---"
        echo "生データ: $line"

        IFS=, read -r region clusterid engine nodetype numnodes pgname enginever subnetgrp sgs at_rest_encryption cluster_mode num_shards transit_encryption maintenance_window auto_upgrade snapshot_enabled snapshot_window snapshot_retention automatic_failover tags snapshot_name restore_mode <<< "$line"

        region=$(echo "$region" | tr -d '\r')
        clusterid=$(echo "$clusterid" | tr -d '\r')
        subnetgrp=$(echo "$subnetgrp" | tr -d '\r')
        snapshot_name=$(echo "$snapshot_name" | tr -d '\r')
        restore_mode=$(echo "$restore_mode" | tr -d '\r')

        echo "リージョン: $region"
        echo "クラスターID: $clusterid"
        echo "復元モード: $restore_mode"
        echo "スナップショット名: $snapshot_name"

        # 復元モードの場合はスナップショットの存在確認
        if [ "$restore_mode" == "enabled" ]; then
            if [ -z "$snapshot_name" ]; then
                echo "エラー: 復元モードですがスナップショット名が指定されていません"
                continue
            fi
            
            if ! check_snapshot_exists "$region" "$snapshot_name"; then
                echo "エラー: スナップショット '$snapshot_name' がリージョン $region に存在しません"
                continue
            fi
            echo "スナップショット確認済み: $snapshot_name"
        else
            # 新規作成モードの場合は通常のバリデーション
            validate_input "$nodetype" "$enginever" "$at_rest_encryption" "$transit_encryption" "$cluster_mode" "$automatic_failover" "$numnodes" || continue
        fi

        check_subnet_group "$region" "$subnetgrp" || continue

        local sg_ids=()
        IFS=';' read -ra sg_array <<< "$sgs"
        for sg in "${sg_array[@]}"; do
            sg=$(echo "$sg" | tr -d '\r')
            echo "セキュリティグループ処理中: $sg"
            sg_id=$(get_security_group_id "$region" "$sg") || continue 2
            sg_ids+=("$sg_id")
        done

        local tags_json=$(parse_tags "$tags")
        local tag_arg=""
        local tags_file=""

        if [ "$tags_json" != "[]" ]; then
            tags_file=$(mktemp)
            echo "$tags_json" > "$tags_file"
            tag_arg="--tags file://$tags_file"
            echo "タグファイル作成: $tags_file"
            echo "タグ内容: $tags_json"
        fi

        if [ "$restore_mode" == "enabled" ]; then
            echo "=== スナップショットから復元 ==="
            
            if [[ "$cluster_mode" == "enabled" ]]; then
                echo "レプリケーショングループとして復元"
                cmd="aws elasticache create-replication-group \
                    --no-cli-pager \
                    --region \"$region\" \
                    --replication-group-id \"$clusterid\" \
                    --replication-group-description \"$clusterid cluster\" \
                    --cache-node-type \"$nodetype\" \
                    --cache-parameter-group-name \"$pgname\" \
                    --cache-subnet-group-name \"$subnetgrp\" \
                    --security-group-ids \"$(IFS=,; echo "${sg_ids[*]}")\" \
                    --snapshot-name \"$snapshot_name\""

                [ "$automatic_failover" == "enabled" ] && cmd+=" --automatic-failover-enabled"
                [ "$at_rest_encryption" == "enabled" ] && cmd+=" --at-rest-encryption-enabled"
                [ "$transit_encryption" == "enabled" ] && cmd+=" --transit-encryption-enabled"
            else
                echo "シングルノードクラスターとして復元"
                cmd="aws elasticache create-cache-cluster \
                    --no-cli-pager \
                    --region \"$region\" \
                    --cache-cluster-id \"$clusterid\" \
                    --cache-node-type \"$nodetype\" \
                    --num-cache-nodes $numnodes \
                    --cache-parameter-group-name \"$pgname\" \
                    --cache-subnet-group-name \"$subnetgrp\" \
                    --security-group-ids \"$(IFS=,; echo "${sg_ids[*]}")\" \
                    --snapshot-name \"$snapshot_name\""

                [ "$transit_encryption" == "enabled" ] && cmd+=" --transit-encryption-enabled"
            fi
        else
            echo "=== 新規クラスター作成 ==="
            
            if [[ "$cluster_mode" == "enabled" ]]; then
                echo "レプリケーショングループで作成"
                local replicas_per_group=1
                local num_node_groups="$num_shards"

                cmd="aws elasticache create-replication-group \
                    --no-cli-pager \
                    --region \"$region\" \
                    --replication-group-id \"$clusterid\" \
                    --replication-group-description \"$clusterid cluster\" \
                    --engine \"$engine\" \
                    --cache-node-type \"$nodetype\" \
                    --num-node-groups $num_node_groups \
                    --replicas-per-node-group $replicas_per_group \
                    --cache-parameter-group-name \"$pgname\" \
                    --engine-version \"$enginever\" \
                    --cache-subnet-group-name \"$subnetgrp\" \
                    --security-group-ids \"$(IFS=,; echo "${sg_ids[*]}")\""

                [ "$automatic_failover" == "enabled" ] && cmd+=" --automatic-failover-enabled"
                [ "$at_rest_encryption" == "enabled" ] && cmd+=" --at-rest-encryption-enabled"
                [ "$transit_encryption" == "enabled" ] && cmd+=" --transit-encryption-enabled"
            else
                echo "シングルノードモードで作成"
                cmd="aws elasticache create-cache-cluster \
                    --no-cli-pager \
                    --region \"$region\" \
                    --cache-cluster-id \"$clusterid\" \
                    --engine \"$engine\" \
                    --cache-node-type \"$nodetype\" \
                    --num-cache-nodes $numnodes \
                    --cache-parameter-group-name \"$pgname\" \
                    --engine-version \"$enginever\" \
                    --cache-subnet-group-name \"$subnetgrp\" \
                    --security-group-ids \"$(IFS=,; echo "${sg_ids[*]}")\""

                [ "$transit_encryption" == "enabled" ] && cmd+=" --transit-encryption-enabled"
            fi
        fi

        [ "$snapshot_enabled" == "enabled" ] && cmd+=" --snapshot-retention-limit $snapshot_retention --preferred-maintenance-window \"$maintenance_window\""
        [ -n "$snapshot_window" ] && [ "$snapshot_window" != "null" ] && cmd+=" --snapshot-window \"$snapshot_window\""
        [ "$auto_upgrade" == "enabled" ] && cmd+=" --auto-minor-version-upgrade" || cmd+=" --no-auto-minor-version-upgrade"
        [ -n "$tag_arg" ] && cmd+=" $tag_arg"

        echo "実行コマンド:"
        echo "$cmd"

        if eval "$cmd"; then
            echo "成功: $clusterid"
        else
            echo "失敗: $clusterid"
        fi

        [ -n "$tags_file" ] && { rm -f "$tags_file"; echo "タグファイル削除: $tags_file"; }
    done < "$1"
}

process_csv "$1"
echo "処理完了"
