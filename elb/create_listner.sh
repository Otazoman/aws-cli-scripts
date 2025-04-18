#!/bin/bash

# CSVファイル名が指定されているか確認
if [ -z "$1" ]; then
    echo "エラー: CSVファイル名を指定してください。"
    exit 1
fi
csv_file="$1"
delimiter=","

# JSONエスケープ関数
json_escape() {
    echo -n "$1" | jq -Rs .
}

# AWS CLI のリージョンを設定
configure_aws_region() {
    local region="$1"
    if [ -n "$region" ]; then
        export AWS_DEFAULT_REGION="$region"
        echo "AWSリージョンを '$region' に設定しました。"
    fi
}

# ロードバランサー ARN を取得 (名前が指定された場合)
get_load_balancer_arn() {
    local region="$1"
    local lb_identifier="$2"
    if [[ "$lb_identifier" =~ ^arn:aws:elasticloadbalancing: ]]; then
        echo "$lb_identifier"
        return
    fi
    aws elbv2 describe-load-balancers --region "$region" --names "$lb_identifier" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null
}

# ターゲットグループ ARN を取得 (名前が指定された場合)
get_target_group_arn() {
    local region="$1"
    local tg_identifier="$2"
    if [[ "$tg_identifier" =~ ^arn:aws:elasticloadbalancing: ]]; then
        echo "$tg_identifier"
        return
    fi
    aws elbv2 describe-target-groups --region "$region" --names "$tg_identifier" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null
}

# 既存リスナーの ARN を取得
get_existing_listener_arn() {
    local region="$1"
    local lb_arn="$2"
    local port="$3"
    local arn=$(aws elbv2 describe-listeners --region "$region" --load-balancer-arn "$lb_arn" --query "Listeners[?Port==\`$port\`].ListenerArn | [0]" --output text 2>/dev/null)
    echo "$arn"
}

# タグを AWS CLI の形式に変換
format_tags() {
    local tags_string="$1"
    if [ -z "$tags_string" ]; then
        echo "[]"
        return
    fi
    
    # jqを使用して安全にJSONを生成
    local tags_json=$(echo -n "$tags_string" | jq -R -s '
        split(";") | 
        map(select(length > 0)) | 
        map(split("=") | {Key: .[0], Value: (.[1:] | join("="))}) |
        {Tags: .}
    ' | jq -c '.Tags')
    
    echo "$tags_json"
}

# デフォルトアクションを生成
generate_default_actions() {
    local action="$1"
    local region="$2"
    local forward_target_groups="$3"
    local target_group_name_or_arn="$4"
    local redirect_url="$5"
    local fixed_response_status_code="$6"
    local fixed_response_message_body="$7"
    local fixed_response_type="$8"
    local lb_type="$9"
    
    case "$action" in
        forward)
            if [ -n "$forward_target_groups" ]; then
                local target_groups="["
                local first=true
                IFS="," read -ra TG_IDENTIFIERS <<< "$forward_target_groups"
                for tg_identifier in "${TG_IDENTIFIERS[@]}"; do
                    local target_group_arn=$(get_target_group_arn "$region" "$tg_identifier")
                    if [ -z "$target_group_arn" ]; then
                        echo "エラー: ターゲットグループ '$tg_identifier' が見つかりません。" >&2
                        return 1
                    fi
                    if ! $first; then
                        target_groups+=","
                    fi
                    target_groups+="{\"TargetGroupArn\":\"$target_group_arn\""
                    if [[ "$lb_type" == "application" ]]; then
                        target_groups+=",\"Weight\":1"
                    fi
                    target_groups+="}"
                    first=false
                done
                target_groups+="]"
                echo "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":$target_groups}}]"
            elif [ -n "$target_group_name_or_arn" ]; then
                local target_group_arn="$target_group_name_or_arn"
                if [[ ! "$target_group_arn" =~ ^arn:aws:elasticloadbalancing: ]] ; then
                    target_group_arn=$(get_target_group_arn "$region" "$target_group_name_or_arn")
                    if [ -z "$target_group_arn" ]; then
                        echo "エラー: ターゲットグループ '$target_group_name_or_arn' が見つかりません。" >&2
                        return 1
                    fi
                fi
                echo "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$target_group_arn\"}]"
            else
                echo "エラー: forward アクションにはターゲットグループが必要です。" >&2
                return 1
            fi
            ;;
        redirect)
            if [ -n "$redirect_url" ] && [ -n "$fixed_response_status_code" ]; then
                local protocol_raw=$(echo "$redirect_url" | cut -d':' -f1 | tr '[:lower:]' '[:upper:]')
                local protocol
                if [[ "$protocol_raw" == "HTTP" || "$protocol_raw" == "HTTPS" ]]; then
                    protocol="$protocol_raw"
                else
                    echo "警告: リダイレクトプロトコルが不明です。HTTPS を使用します。" >&2
                    protocol="HTTPS"
                fi
                local rest=$(echo "$redirect_url" | cut -d':' -f2- | sed 's/^\/\///')
                local host_port=$(echo "$rest" | cut -d'/' -f1)
                local path="/$(echo "$rest" | cut -d'/' -f2-)"
                local host=$(echo "$host_port" | cut -d':' -f1)
                local port=$(echo "$host_port" | cut -d':' -f2)
                local redirect_config="{\"Protocol\":\"$protocol\""
                if [ -n "$host" ]; then
                    redirect_config+=",\"Host\":\"$host\""
                fi
                if [ -n "$port" ]; then
                    redirect_config+=",\"Port\":\"$port\""
                fi
                if [ -n "$path" ] && [ "$path" != "/" ]; then
                    redirect_config+=",\"Path\":\"$path\""
                fi
                redirect_config+=",\"StatusCode\":\"HTTP_$fixed_response_status_code\"}"
                echo "[{\"Type\":\"redirect\",\"RedirectConfig\":$redirect_config}]"
            else
                echo "エラー: redirect アクションにはリダイレクトURLとステータスコードが必要です。" >&2
                return 1
            fi
            ;;
        "fixed-response")
            if [ -n "$fixed_response_status_code" ]; then
                local fixed_response_config="{\"StatusCode\":\"$fixed_response_status_code\""
                if [ -n "$fixed_response_message_body" ]; then
                    local escaped_body=$(json_escape "$fixed_response_message_body")
                    fixed_response_config+=",\"MessageBody\":$escaped_body"
                fi
                if [ -n "$fixed_response_type" ]; then
                    fixed_response_config+=",\"ContentType\":\"$fixed_response_type\""
                fi
                fixed_response_config+="}"
                echo "[{\"Type\":\"fixed-response\",\"FixedResponseConfig\":$fixed_response_config}]"
            else
                echo "エラー: fixed-response アクションにはステータスコードが必要です。" >&2
                return 1
            fi
            ;;
        *)
            echo "エラー: 不明なアクション '$action' です。" >&2
            return 1
            ;;
    esac
}

# メイン処理
while IFS="$delimiter" read -r -a line; do
    # ヘッダー行をスキップ
    if [[ "${line[0]}" == "REGION" ]]; then
        continue
    fi

    REGION="${line[0]}"
    LOADBALANCERARN="${line[1]}"
    LISTENERPORT="${line[2]}"
    PROTOCOL="${line[3]}"
    LOADBALANCERTYPE="${line[4]}"
    TARGETGROUPNAMEORARN="${line[5]}"
    CERTIFICATEARN="${line[6]}"
    SSLPOLICY="${line[7]}"
    ACTION="${line[8]}"
    FORWARDTARGETGROUPS="${line[9]}"
    REDIRECTURL="${line[10]}"
    FIXEDRESPONSESTATUSCODE="${line[11]}"
    FIXEDRESPONSEMESSAGEBODY="${line[12]}"
    FIXEDRESPONSETYPE="${line[13]}"
    TAGS="${line[14]}"

    echo "処理中のリスナー: LoadBalancer=$LOADBALANCERARN, Port=$LISTENERPORT, Protocol=$PROTOCOL, Type=$LOADBALANCERTYPE, リージョン=$REGION, アクション=$ACTION"
    configure_aws_region "$REGION"

    # ロードバランサー ARN を取得
    LoadBalancerArn=$(get_load_balancer_arn "$REGION" "$LOADBALANCERARN")
    if [ -z "$LoadBalancerArn" ]; then
        echo "エラー: ロードバランサー '$LOADBALANCERARN' が見つかりません。"
        continue
    fi

    # 既存リスナーの ARN を確認
    ExistingListenerArn=$(get_existing_listener_arn "$REGION" "$LoadBalancerArn" "$LISTENERPORT")
    if [ "$ExistingListenerArn" == "None" ]; then
        ExistingListenerArn=""
    fi

    # デフォルトアクションを生成
    default_actions_json=$(generate_default_actions \
        "$ACTION" \
        "$REGION" \
        "$FORWARDTARGETGROUPS" \
        "$TARGETGROUPNAMEORARN" \
        "$REDIRECTURL" \
        "$FIXEDRESPONSESTATUSCODE" \
        "$FIXEDRESPONSEMESSAGEBODY" \
        "$FIXEDRESPONSETYPE" \
        "$LOADBALANCERTYPE"
    )

    if [ $? -ne 0 ]; then
        echo "$default_actions_json" >&2
        continue
    fi

    # タグの設定
    tags_json=$(format_tags "$TAGS")

    # リスナーの作成または変更
    if [ -z "$ExistingListenerArn" ]; then
        echo "    リスナーを作成します (ポート: $LISTENERPORT, プロトコル: $PROTOCOL, アクション: $ACTION)"
        
        # 基本コマンド
        cmd=(aws elbv2 create-listener --region "$REGION" --load-balancer-arn "$LoadBalancerArn" --protocol "$PROTOCOL" --port "$LISTENERPORT")
        
        # デフォルトアクションを追加
        cmd+=(--default-actions "$default_actions_json")
        
        # HTTPS/TLSの場合の追加オプション
        if [[ "$PROTOCOL" == "HTTPS" || "$PROTOCOL" == "TLS" ]]; then
            if [ -n "$CERTIFICATEARN" ]; then
                cmd+=(--certificates "CertificateArn=$CERTIFICATEARN")
            fi
            if [ -n "$SSLPOLICY" ]; then
                cmd+=(--ssl-policy "$SSLPOLICY")
            fi
        fi
        
        # タグがある場合
        if [ "$tags_json" != "[]" ]; then
            cmd+=(--tags "$tags_json")
        fi
        
        # コマンド実行
        "${cmd[@]}"
        
        if [ $? -ne 0 ]; then
            echo "エラー: リスナーの作成に失敗しました"
            continue
        fi
    else
        echo "    既存のリスナーが見つかりました (ARN: $ExistingListenerArn)。設定を変更します (アクション: $ACTION)"
        
        # 基本コマンド
        cmd=(aws elbv2 modify-listener --region "$REGION" --listener-arn "$ExistingListenerArn" --protocol "$PROTOCOL" --port "$LISTENERPORT")
        
        # デフォルトアクションを追加
        cmd+=(--default-actions "$default_actions_json")
        
        # HTTPS/TLSの場合の追加オプション
        if [[ "$PROTOCOL" == "HTTPS" || "$PROTOCOL" == "TLS" ]]; then
            if [ -n "$SSLPOLICY" ]; then
                cmd+=(--ssl-policy "$SSLPOLICY")
            fi
            if [ -n "$CERTIFICATEARN" ]; then
                echo "    警告: 証明書の変更は手動で行う必要があります。"
            fi
        fi
        
        # コマンド実行
        "${cmd[@]}"
        
        if [ $? -ne 0 ]; then
            echo "エラー: リスナーの変更に失敗しました"
            continue
        fi
        
        # タグの更新
        if [ "$tags_json" != "[]" ]; then
            echo "    タグを更新します"
            aws elbv2 add-tags --region "$REGION" --resource-arns "$ExistingListenerArn" --tags "$tags_json"
        fi
    fi
    echo ""
done < <(cat "$csv_file" | tr -d '\r')

echo "処理が完了しました。"
