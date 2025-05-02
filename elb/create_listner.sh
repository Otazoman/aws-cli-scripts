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
    local lb_type="$3"
    if [[ "$lb_identifier" =~ ^arn:aws:elasticloadbalancing: ]]; then
        echo "$lb_identifier"
        return
    fi
    aws elbv2 describe-load-balancers --region "$region" --names "$lb_identifier" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null
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
                    if [[ "$lb_type" == "ALB" || "$lb_type" == "application" ]]; then
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
    RULE_JSON_PATH="${line[15]}"

    echo "処理中のリスナー設定: LoadBalancer=$LOADBALANCERARN, Port=$LISTENERPORT, Type=$LOADBALANCERTYPE, リージョン=$REGION"
    configure_aws_region "$REGION"

    # ロードバランサー ARN を取得
    LoadBalancerArn=$(get_load_balancer_arn "$REGION" "$LOADBALANCERARN" "$LOADBALANCERTYPE")
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

    # リスナーの作成または更新
    if [ -z "$ExistingListenerArn" ]; then
        echo "  リスナーを作成します (ポート: $LISTENERPORT, プロトコル: $PROTOCOL, アクション: $ACTION)"
        
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
        tags_json=$(format_tags "$TAGS")
        if [ "$tags_json" != "[]" ]; then
            cmd+=(--tags "$tags_json")
        fi
        
        # コマンド実行
        listener_arn=$("${cmd[@]}" --query 'Listeners[0].ListenerArn' --output text)
        if [ $? -ne 0 ]; then
            echo "エラー: リスナーの作成に失敗しました"
            continue
        fi
        ExistingListenerArn="$listener_arn"
    else
        echo "  既存のリスナーが見つかりました (ARN: $ExistingListenerArn)。設定を更新します"
        
        # 基本コマンド
        cmd=(aws elbv2 modify-listener --region "$REGION" --listener-arn "$ExistingListenerArn")
        
        # プロトコルとポートを指定 (変更する場合)
        cmd+=(--protocol "$PROTOCOL" --port "$LISTENERPORT")
        
        # デフォルトアクションを追加
        cmd+=(--default-actions "$default_actions_json")
        
        # HTTPS/TLSの場合の追加オプション
        if [[ "$PROTOCOL" == "HTTPS" || "$PROTOCOL" == "TLS" ]]; then
            if [ -n "$SSLPOLICY" ]; then
                cmd+=(--ssl-policy "$SSLPOLICY")
            fi
            if [ -n "$CERTIFICATEARN" ]; then
                cmd+=(--certificates "CertificateArn=$CERTIFICATEARN")
            fi
        fi
        
        # コマンド実行
        "${cmd[@]}"
        if [ $? -ne 0 ]; then
            echo "エラー: リスナーの更新に失敗しました"
            continue
        fi
        
        # タグの更新
        tags_json=$(format_tags "$TAGS")
        if [ "$tags_json" != "[]" ]; then
            echo "    タグを更新します"
            aws elbv2 add-tags --region "$REGION" --resource-arns "$ExistingListenerArn" --tags "$tags_json"
        fi
    fi

# ALB の場合、リスナールールを処理
if [[ "$LOADBALANCERTYPE" == "ALB" ]] && [ -n "$RULE_JSON_PATH" ] && [ -f "$RULE_JSON_PATH" ]; then
    echo "  リスナールールを JSON ファイルから読み込みます: $RULE_JSON_PATH"
    rule_json_array_content=$(cat "$RULE_JSON_PATH" 2>/dev/null)

    if [ -z "$rule_json_array_content" ]; then
        echo "警告: JSON ファイル '$RULE_JSON_PATH' が空または読み込みできません。" >&2
        continue
    fi

    # JSONが有効な配列かチェック
    if ! echo "$rule_json_array_content" | jq -e 'type == "array"' > /dev/null 2>&1; then
        echo "警告: JSON ファイル '$RULE_JSON_PATH' の内容が有効なJSON配列ではありません。リスナールールは処理しません。" >&2
        continue
    fi

    # JSON配列の各ルールオブジェクトを処理
    echo "$rule_json_array_content" | jq -c '.[]' | while IFS= read -r rule_obj_json; do
        # 各ルールオブジェクトからPriority, Conditions, Actionsを抽出
        priority=$(echo "$rule_obj_json" | jq -r '.Priority' 2>/dev/null)
        conditions=$(echo "$rule_obj_json" | jq -c '.Conditions' 2>/dev/null)
        actions=$(echo "$rule_obj_json" | jq -c '.Actions' 2>/dev/null)

        # 必須フィールドの存在チェック
        if [ "$priority" == "null" ] || [ -z "$priority" ]; then
            echo "警告: ルールJSONオブジェクトから 'Priority' を取得できませんでした。このルールはスキップします: $rule_obj_json" >&2
            continue
        fi
         if [ "$conditions" == "null" ] || [ -z "$conditions" ]; then
            echo "警告: ルール (優先度: $priority) のJSONオブジェクトから 'Conditions' を取得できませんでした。このルールはスキップします: $rule_obj_json" >&2
            continue
        fi
        if [ "$actions" == "null" ] || [ -z "$actions" ]; then
            echo "警告: ルール (優先度: $priority) のJSONオブジェクトから 'Actions' を取得できませんでした。このルールはスキップします: $rule_obj_json" >&2
            continue
        fi


        # 既存ルールを確認
        existing_rule_arn=$(aws elbv2 describe-rules --region "$REGION" --listener-arn "$ExistingListenerArn" \
            --query "Rules[?Priority==\`$priority\`].RuleArn | [0]" --output text 2>/dev/null)

        if [ "$existing_rule_arn" == "None" ] || [ -z "$existing_rule_arn" ]; then
            echo "    ルールを作成します (優先度: $priority)"
            # ルール作成コマンド
            create_rule_cmd=(aws elbv2 create-rule \
                --region "$REGION" \
                --listener-arn "$ExistingListenerArn" \
                --priority "$priority" \
                --conditions "$conditions" \
                --actions "$actions")

            "${create_rule_cmd[@]}" > /dev/null # 出力は破棄
            if [ $? -ne 0 ]; then
                echo "エラー: リスナールール (優先度: $priority) の作成に失敗しました" >&2
            fi
        else
            echo "    既存のルールを更新します (ARN: $existing_rule_arn, 優先度: $priority)"
            # ルール更新コマンド
            modify_rule_cmd=(aws elbv2 modify-rule \
                --region "$REGION" \
                --rule-arn "$existing_rule_arn" \
                --conditions "$conditions" \
                --actions "$actions")

             "${modify_rule_cmd[@]}" > /dev/null # 出力は破棄
             if [ $? -ne 0 ]; then
                echo "エラー: リスナールール (ARN: $existing_rule_arn) の更新に失敗しました" >&2
             fi

        fi
    done
else
    # RULE_JSON_PATHが指定されていないか、ファイルが存在しない場合
    if [[ "$LOADBALANCERTYPE" == "ALB" ]] && [ -n "$RULE_JSON_PATH" ] && [ ! -f "$RULE_JSON_PATH" ]; then
         echo "警告: 指定されたルールJSONファイル '$RULE_JSON_PATH' が見つかりません。このリスナーの追加ルールは処理しません。" >&2
    elif [[ "$LOADBALANCERTYPE" == "ALB" ]] && [ -z "$RULE_JSON_PATH" ]; then
         echo "情報: ルールJSONファイルが指定されていません。このリスナーに追加ルールは作成/更新しません。"
    fi
fi

    echo ""
done < <(cat "$csv_file" | tr -d '\r')

echo "処理が完了しました。"
