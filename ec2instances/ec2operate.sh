#!/bin/bash
set -e

# コマンドライン引数からCSVファイル名を取得
if [ $# -ne 1 ]; then
  echo "Usage: $0 <csv-file>"
  exit 1
fi

CSV_FILE="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# ヘッダー行を読み飛ばす
HEADER=$(head -n 1 "$CSV_FILE")

# 2行目以降（実データ）を処理
tail -n +2 "$CSV_FILE" | while IFS=, read -r ACTION REGION NAME IMAGEID INSTANCETYPE KEYNAME SUBNETNAME SECURITYGROUPNAMES PRIVATEIPADDRESS DISABLEAPITERMINATION TAGS VOLUMESIZE VOLUMETYPE ALLOCATEELASTICIP ADDITIONALVOLUMESIZES ADDITIONALVOLUMETYPES IAMINSTANCEPROFILE OSTYPE CLOUDWATCHMONITORING PURCHASEOPTION USERDATA
do
  AWS_REGION="${REGION:-ap-northeast-1}"
  
  # アクション判定
  if [[ "$ACTION" == "remove" ]]; then
    echo "インスタンス削除処理開始 $NAME region $AWS_REGION"
    
    # インスタンスIDを取得
    INSTANCE_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
      --filters "Name=tag:Name,Values=$NAME" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text)
    
    if [ -z "$INSTANCE_ID" ]; then
      echo "Warning: Instance $NAME not found in $AWS_REGION. Skipping..."
      echo "----------------------------------"
      continue
    fi

    # 削除保護を解除
    if aws ec2 modify-instance-attribute --region "$AWS_REGION" \
      --instance-id "$INSTANCE_ID" \
      --no-disable-api-termination 2>/dev/null; then
      echo "Termination protection disabled for $INSTANCE_ID"
    else
      echo "Warning: Failed to disable termination protection for $INSTANCE_ID (may already be disabled)"
    fi

    # Elastic IPを解放
    ALLOC_ID=$(aws ec2 describe-addresses --region "$AWS_REGION" \
      --filters "Name=instance-id,Values=$INSTANCE_ID" \
      --query "Addresses[0].AllocationId" \
      --output text)
    
    if [[ -n "$ALLOC_ID" && "$ALLOC_ID" != "None" ]]; then
      ASSOCIATION_ID=$(aws ec2 describe-addresses --region "$AWS_REGION" \
        --filters "Name=instance-id,Values=$INSTANCE_ID" \
        --query "Addresses[0].AssociationId" \
        --output text)
      
      if [ -n "$ASSOCIATION_ID" ]; then
        if aws ec2 disassociate-address --region "$AWS_REGION" \
          --association-id "$ASSOCIATION_ID"; then
          echo "Elastic IP disassociated: $ASSOCIATION_ID"
        else
          echo "Warning: Failed to disassociate Elastic IP $ASSOCIATION_ID"
        fi
      fi
      
      if aws ec2 release-address --region "$AWS_REGION" \
        --allocation-id "$ALLOC_ID"; then
        echo "Elastic IP released: $ALLOC_ID"
      else
        echo "Warning: Failed to release Elastic IP $ALLOC_ID"
      fi
    fi

    # インスタンスを終了
    echo "Terminating instance $INSTANCE_ID..."
    if aws ec2 terminate-instances --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID"; then
      
      # インスタンスが完全に終了するまで待機 (最大5分)
      echo "Waiting for instance to terminate..."
      if aws ec2 wait instance-terminated --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID"; then
        echo "Instance $INSTANCE_ID terminated successfully"
      else
        echo "Warning: Instance termination not confirmed, but continuing..."
      fi
    else
      echo "Error: Failed to terminate instance $INSTANCE_ID"
      echo "----------------------------------"
      continue
    fi

    # 追加ボリュームを削除 (インスタンス終了後に行う)
    VOLUME_IDS=$(aws ec2 describe-volumes --region "$AWS_REGION" \
      --filters "Name=tag:Name,Values=$NAME-vol*" \
      --query "Volumes[].VolumeId" \
      --output text)
    
    if [ -z "$VOLUME_IDS" ]; then
      echo "No additional volumes found for $NAME"
    else
      for VOL_ID in $VOLUME_IDS; do
        echo "Processing volume $VOL_ID..."
        
        # ボリューム状態を確認
        VOLUME_STATE=$(aws ec2 describe-volumes --region "$AWS_REGION" \
          --volume-ids "$VOL_ID" \
          --query "Volumes[0].State" \
          --output text 2>/dev/null || echo "not-found")
        
        if [ "$VOLUME_STATE" == "not-found" ]; then
          echo "Volume $VOL_ID not found (may already be deleted)"
          continue
        fi

        # ボリュームが利用可能な状態になるまで待機 (最大3分)
        if [ "$VOLUME_STATE" != "available" ]; then
          echo "Waiting for volume $VOL_ID to become available..."
          if aws ec2 wait volume-available --region "$AWS_REGION" \
            --volume-ids "$VOL_ID" --max-attempts 30; then
            echo "Volume $VOL_ID is now available"
          else
            echo "Warning: Volume $VOL_ID did not become available in time, skipping..."
            continue
          fi
        fi

        # ボリューム削除
        if aws ec2 delete-volume --region "$AWS_REGION" \
          --volume-id "$VOL_ID"; then
          echo "Volume $VOL_ID deleted successfully"
        else
          echo "Warning: Failed to delete volume $VOL_ID"
        fi
      done
    fi

    echo "インスタンス削除処理完了 $NAME"
    echo "----------------------------------"
    continue
  elif [[ "$ACTION" != "add" ]]; then
    echo "Error: Invalid action '$ACTION'. Skipping."
    echo "----------------------------------"
    continue
  fi


  echo "インスタンス作成開始 $NAME region $AWS_REGION"

  # 既存インスタンスのチェック
  EXISTING_INSTANCE=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,stopped,pending,shutting-down,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
  
  if [ -n "$EXISTING_INSTANCE" ]; then
    echo "Warning: Instance $NAME already exists with ID $EXISTING_INSTANCE. Skipping..."
    echo "----------------------------------"
    continue
  fi

  # OSタイプに応じたデバイス名の設定
  case "$OSTYPE" in
    linux)
      ROOT_DEVICE_NAME="/dev/xvda"
      ADDITIONAL_DEVICE_PREFIX="/dev/xvd"
      ;;
    windows)
      ROOT_DEVICE_NAME="/dev/sda1"
      ADDITIONAL_DEVICE_PREFIX="/dev/sd"
      ;;
    *)
      ROOT_DEVICE_NAME="/dev/xvda"
      ADDITIONAL_DEVICE_PREFIX="/dev/xvd"
      ;;
  esac

  # キーペア確認と作成
  if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEYNAME" &> /dev/null; then
    echo "Key pair $KEYNAME not found in $AWS_REGION. Creating a new one..."
    aws ec2 create-key-pair --region "$AWS_REGION" --key-name "$KEYNAME" \
      --query 'KeyMaterial' --output text > ~/.ssh/"$KEYNAME".pem
    chmod 400 ~/.ssh/"$KEYNAME".pem
  fi

  # サブネットID取得
  if [[ "$SUBNETNAME" =~ ^subnet- ]]; then
    SUBNETID="$SUBNETNAME"
  else
    SUBNETID=$(aws ec2 describe-subnets --region "$AWS_REGION" \
      --filters "Name=tag:Name,Values=$SUBNETNAME" \
      --query "Subnets[0].SubnetId" --output text)
    [ -z "$SUBNETID" ] && { echo "Error: Subnet $SUBNETNAME not found"; continue; }
  fi

  # VPC ID取得
  VPC_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --subnet-ids "$SUBNETID" \
    --query "Subnets[0].VpcId" --output text)

  # セキュリティグループID取得
  SECURITYGROUPIDS=()
  if [ -n "$SECURITYGROUPNAMES" ]; then
    IFS=';' read -r -a SG_NAMES <<< "$SECURITYGROUPNAMES"
    for SG_NAME in "${SG_NAMES[@]}"; do
      if [[ "$SG_NAME" =~ ^sg- ]]; then
        SG_ID="$SG_NAME"
      else
        SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
          --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
          --query "SecurityGroups[0].GroupId" --output text)
        [ -z "$SG_ID" ] && { echo "Error: Security group $SG_NAME not found"; continue; }
      fi
      SECURITYGROUPIDS+=("$SG_ID")
    done
  fi

  # タグ解析処理
  TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=$NAME}"
  if [[ -n "$TAGS" && "$TAGS" != "null" ]]; then
    IFS=';' read -r -a TAG_PAIRS <<< "$TAGS"
    for TAG_PAIR in "${TAG_PAIRS[@]}"; do
      IFS='=' read -r TAG_KEY TAG_VALUE <<< "$TAG_PAIR"
      TAG_KEY=$(echo "$TAG_KEY" | xargs)
      TAG_VALUE=$(echo "$TAG_VALUE" | xargs)
      if [[ -n "$TAG_KEY" && -n "$TAG_VALUE" ]]; then
        TAG_SPEC+=",{Key=$TAG_KEY,Value=$TAG_VALUE}"
      fi
    done
  fi
  TAG_SPEC+="]"

  # インスタンス作成コマンドの基本オプション
  INSTANCE_OPTS=(
    --region "$AWS_REGION"
    --image-id "$IMAGEID"
    --instance-type "$INSTANCETYPE"
    --key-name "$KEYNAME"
    --subnet-id "$SUBNETID"
    --tag-specifications "$TAG_SPEC"
    --block-device-mappings "[{
      \"DeviceName\":\"$ROOT_DEVICE_NAME\",
      \"Ebs\":{
        \"VolumeSize\":$VOLUMESIZE,
        \"VolumeType\":\"$VOLUMETYPE\",
        \"Encrypted\":true
      }
    }]"
  )

  # セキュリティグループが指定されている場合
  if [ ${#SECURITYGROUPIDS[@]} -gt 0 ]; then
    INSTANCE_OPTS+=(--security-group-ids "${SECURITYGROUPIDS[@]}")
  fi

  # プライベートIPアドレスが指定されている場合
  if [ -n "$PRIVATEIPADDRESS" ]; then
    INSTANCE_OPTS+=(--private-ip-address "$PRIVATEIPADDRESS")
  fi

  # 終了保護設定
  if [[ "$DISABLEAPITERMINATION" == "TRUE" ]]; then
    INSTANCE_OPTS+=(--disable-api-termination)
  else
    INSTANCE_OPTS+=(--enable-api-termination)
  fi

  # CloudWatch詳細モニタリング
  if [[ "$CLOUDWATCHMONITORING" == "TRUE" ]]; then
    INSTANCE_OPTS+=(--monitoring "Enabled=true")
  else
    INSTANCE_OPTS+=(--monitoring "Enabled=false")
  fi

  # 購入オプション (スポットインスタンス)
  if [[ "$PURCHASEOPTION" == "spot" ]]; then
    INSTANCE_OPTS+=(--instance-market-options '{"MarketType":"spot"}')
  fi

  # ユーザーデータ
  if [[ -n "$USERDATA" && "$USERDATA" != "null" ]]; then
    echo "Including user-data file: $USERDATA"
    # AWS CLIがファイル読み込みとBase64エンコードを行う
    # パスはスクリプト実行時のカレントディレクトリからの相対パスまたは絶対パス
    INSTANCE_OPTS+=(--user-data "file://$USERDATA")
  fi

  # インスタンス作成
  INSTANCE_ID=$(aws ec2 run-instances "${INSTANCE_OPTS[@]}" \
    --query 'Instances[0].InstanceId' --output text)

  echo "Instance $NAME created successfully in $AWS_REGION"
  echo "Instance ID: $INSTANCE_ID"

  # インスタンスの起動を待つ
  echo "Waiting for instance $INSTANCE_ID to enter 'running' state..."
  aws ec2 wait instance-running --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID"

  # rootボリュームにタグ付与
  ROOT_VOLUME_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='$ROOT_DEVICE_NAME'].Ebs.VolumeId" \
    --output text)
  
  VOLUME_TAGS="Key=Name,Value=$NAME-root"
  if [[ -n "$TAGS" && "$TAGS" != "null" ]]; then
    IFS=';' read -r -a TAG_PAIRS <<< "$TAGS"
    for TAG_PAIR in "${TAG_PAIRS[@]}"; do
      IFS='=' read -r TAG_KEY TAG_VALUE <<< "$TAG_PAIR"
      TAG_KEY=$(echo "$TAG_KEY" | xargs)
      TAG_VALUE=$(echo "$TAG_VALUE" | xargs)
      if [[ -n "$TAG_KEY" && -n "$TAG_VALUE" ]]; then
        VOLUME_TAGS+=" Key=$TAG_KEY,Value=$TAG_VALUE"
      fi
    done
  fi
  
  aws ec2 create-tags --resources "$ROOT_VOLUME_ID" --tags $VOLUME_TAGS

  # Elastic IP処理
  if [[ "$ALLOCATEELASTICIP" == "TRUE" ]]; then
    ALLOC_ID=$(aws ec2 allocate-address --region "$AWS_REGION" \
      --query 'AllocationId' --output text)
    aws ec2 associate-address --region "$AWS_REGION" \
      --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID"
    
    EIP_TAGS="Key=Name,Value=$NAME"
    if [[ -n "$TAGS" && "$TAGS" != "null" ]]; then
      IFS=';' read -r -a TAG_PAIRS <<< "$TAGS"
      for TAG_PAIR in "${TAG_PAIRS[@]}"; do
        IFS='=' read -r TAG_KEY TAG_VALUE <<< "$TAG_PAIR"
        TAG_KEY=$(echo "$TAG_KEY" | xargs)
        TAG_VALUE=$(echo "$TAG_VALUE" | xargs)
        if [[ -n "$TAG_KEY" && -n "$TAG_VALUE" ]]; then
          EIP_TAGS+=" Key=$TAG_KEY,Value=$TAG_VALUE"
        fi
      done
    fi
    
    aws ec2 create-tags --region "$AWS_REGION" \
      --resources "$ALLOC_ID" --tags $EIP_TAGS
  fi

  # インスタンスの AZ を取得
  INSTANCE_AZ=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
    --output text)

  # 追加ストレージ処理
  if [[ -n "$ADDITIONALVOLUMESIZES" && "$ADDITIONALVOLUMESIZES" != "null" ]]; then
    IFS=';' read -r -a SIZES <<< "$ADDITIONALVOLUMESIZES"
    IFS=';' read -r -a TYPES <<< "$ADDITIONALVOLUMETYPES"

    for i in "${!SIZES[@]}"; do
      VOL_ID=$(aws ec2 create-volume --region "$AWS_REGION" \
        --availability-zone "$INSTANCE_AZ" \
        --size "${SIZES[$i]}" \
        --volume-type "${TYPES[$i]}" \
        --encrypted \
        --query 'VolumeId' --output text)

      echo "Created volume: $VOL_ID in $INSTANCE_AZ"

      # ボリュームがavailableになるまで待機
      aws ec2 wait volume-available --region "$AWS_REGION" \
        --volume-ids "$VOL_ID"

      # 追加デバイス名を設定
      DEVICE_NAME="${ADDITIONAL_DEVICE_PREFIX}$(echo {b..z} | cut -d ' ' -f $((i+1)))"
      
      aws ec2 attach-volume --region "$AWS_REGION" \
        --instance-id "$INSTANCE_ID" \
        --device "$DEVICE_NAME" \
        --volume-id "$VOL_ID"

      # 追加ボリュームにタグ付与
      VOLUME_TAGS="Key=Name,Value=$NAME-vol$((i+1))"
      if [[ -n "$TAGS" && "$TAGS" != "null" ]]; then
        IFS=';' read -r -a TAG_PAIRS <<< "$TAGS"
        for TAG_PAIR in "${TAG_PAIRS[@]}"; do
          IFS='=' read -r TAG_KEY TAG_VALUE <<< "$TAG_PAIR"
          TAG_KEY=$(echo "$TAG_KEY" | xargs)
          TAG_VALUE=$(echo "$TAG_VALUE" | xargs)
          if [[ -n "$TAG_KEY" && -n "$TAG_VALUE" ]]; then
            VOLUME_TAGS+=" Key=$TAG_KEY,Value=$TAG_VALUE"
          fi
        done
      fi

      aws ec2 create-tags --resources "$VOL_ID" --tags $VOLUME_TAGS
    done
  fi

  # IAMロール処理
  if [[ -n "$IAMINSTANCEPROFILE" && "$IAMINSTANCEPROFILE" != "null" ]]; then
    aws ec2 associate-iam-instance-profile --region "$AWS_REGION" \
      --instance-id "$INSTANCE_ID" \
      --iam-instance-profile "Name=$IAMINSTANCEPROFILE"
  fi

  echo "インスタンス作成完了 $NAME "
  echo "----------------------------------"
done
