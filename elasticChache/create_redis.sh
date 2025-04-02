#!/bin/bash

usage() {
    echo "使用方法: $0 <CSVファイルパス>"
    echo "例: $0 elasticache_params.csv"
    exit 1
}

if [ $# -ne 1 ]; then
    echo "エラー: CSVファイルを1つ指定する必要があります"
    usage
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
    echo "エラー: CSVファイルが見つかりません: $CSV_FILE"
    exit 1
fi

get_security_group_id() {
    local region=$1
    local sg_identifier=$2
    local sg_id

    if [[ $sg_identifier =~ ^sg-[a-z0-9]+$ ]]; then
        echo "$sg_identifier"
        return 0
    fi

    sg_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=$sg_identifier" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>/dev/null)

    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
        echo "エラー: セキュリティグループ '$sg_identifier' をリージョン $region で見つけられません" >&2
        return 1
    fi

    echo "$sg_id"
}

parse_tags() {
    local tags_str=$1
    if [ -z "$tags_str" ] || [ "$tags_str" == "null" ]; then
        echo "[]"
        return
    fi

    IFS=';' read -ra TAG_PAIRS <<< "$tags_str"
    local tags_json="["
    for pair in "${TAG_PAIRS[@]}"; do
        IFS='=' read -r key value <<< "$pair"
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        tags_json+="{\"Key\":\"$key\",\"Value\":\"$value\"},"
    done
    tags_json="${tags_json%,}]"
    echo "$tags_json"
}

{
    read -r header

    expected_header="REGION,CLUSTERID,ENGINE,NODETYPE,NUMCACHENODES,PARAMETERGROUPNAME,ENGINEVERSION,CACHESUBNETGROUPNAME,SECURITYGROUPIDENTIFIERS,DATA_TIERING,AT_REST_ENCRYPTION,CLUSTER_MODE,NUM_SHARDS,IN_TRANSIT_ENCRYPTION,MAINTENANCE_WINDOW,AUTO_UPGRADE,SNAPSHOT_ENABLED,SNAPSHOT_WINDOW,SNAPSHOT_RETENTION,TAGS"
    if [[ $header != "$expected_header" ]]; then
        echo "エラー: CSVヘッダー形式が正しくありません。以下のヘッダーが必要です:"
        echo "$expected_header"
        exit 1
    fi

    while IFS=, read -r REGION CLUSTERID ENGINE NODETYPE NUMCACHENODES PARAMETERGROUPNAME ENGINEVERSION CACHESUBNETGROUPNAME SECURITYGROUPIDENTIFIERS DATA_TIERING AT_REST_ENCRYPTION CLUSTER_MODE NUM_SHARDS IN_TRANSIT_ENCRYPTION MAINTENANCE_WINDOW AUTO_UPGRADE SNAPSHOT_ENABLED SNAPSHOT_WINDOW SNAPSHOT_RETENTION TAGS
    do
        echo "リージョン $REGION にElastiCacheクラスターを作成中: $CLUSTERID"

        IFS=';' read -ra SG_ARRAY <<< "$SECURITYGROUPIDENTIFIERS"
        SG_IDS=()
        for sg in "${SG_ARRAY[@]}"; do
            sg_id=$(get_security_group_id "$REGION" "$sg")
            if [ $? -ne 0 ]; then
                echo "エラー: $CLUSTERID の作成をスキップします"
                continue 2
            fi
            SG_IDS+=("$sg_id")
        done

        SG_IDS_JOINED=$(IFS=,; echo "${SG_IDS[*]}")
        TAGS_JSON=$(parse_tags "$TAGS")

        CMD="aws elasticache create-replication-group \
            --region \"$REGION\" \
            --replication-group-id \"$CLUSTERID\" \
            --replication-group-description \"$CLUSTERID cluster\" \
            --engine \"$ENGINE\" \
            --cache-node-type \"$NODETYPE\" \
            --num-node-groups $NUM_SHARDS \
            --replicas-per-node-group 1 \
            --cache-parameter-group-name \"$PARAMETERGROUPNAME\" \
            --engine-version \"$ENGINEVERSION\" \
            --cache-subnet-group-name \"$CACHESUBNETGROUPNAME\" \
            --security-group-ids \"$SG_IDS_JOINED\""

        if [[ "$AT_REST_ENCRYPTION" == "enabled" ]]; then
            CMD+=" --at-rest-encryption-enabled"
        fi
        if [[ "$IN_TRANSIT_ENCRYPTION" == "enabled" ]]; then
            CMD+=" --transit-encryption-enabled"
        fi

        if [[ -n "$TAGS_JSON" && "$TAGS_JSON" != "[]" ]]; then
            TAGS_FILE=$(mktemp)
            echo "$TAGS_JSON" > "$TAGS_FILE"
            CMD+=" --tags file://$TAGS_FILE"
        fi

        echo "実行コマンド:"
        echo "$CMD"

        eval "$CMD"
        RESULT=$?
        [[ -n "$TAGS_FILE" ]] && rm -f "$TAGS_FILE"

        if [ $RESULT -eq 0 ]; then
            echo "成功: $REGION リージョンにElastiCacheクラスター $CLUSTERID の作成を開始しました"
        else
            echo "エラー: $REGION リージョンでのElastiCacheクラスター $CLUSTERID の作成に失敗しました"
            echo "ヒント: パラメータグループや暗号化設定が適切か確認してください"
        fi

    done
} < "$CSV_FILE"

echo "すべてのElastiCacheクラスター作成リクエストが処理されました"

