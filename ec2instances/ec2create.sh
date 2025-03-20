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
tail -n +2 "$CSV_FILE" | while IFS=, read -r REGION NAME IMAGEID INSTANCETYPE KEYNAME SUBNETNAME SECURITYGROUPNAMES PRIVATEIPADDRESS DISABLEAPITERMINATION COST_TAG VOLUMESIZE VOLUMETYPE ALLOCATEELASTICIP ADDITIONALVOLUMESIZES ADDITIONALVOLUMETYPES IAMINSTANCEPROFILE OSTYPE
do
  AWS_REGION="${REGION:-ap-northeast-1}"
  echo "インスタンス作成開始 $NAME region $AWS_REGION"

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
      ROOT_DEVICE_NAME="/dev/xvda"  # デフォルト値
      ADDITIONAL_DEVICE_PREFIX="/dev/xvd"
      ;;
  esac
  echo "Root Device Name: $ROOT_DEVICE_NAME"
  echo "Additional Device Prefix: $ADDITIONAL_DEVICE_PREFIX"

  # ~/.ssh/ ディレクトリを作成（存在しない場合）
  mkdir -p ~/.ssh/

  # キーペア確認と作成
  if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEYNAME" &> /dev/null; then
    echo "Key pair $KEYNAME not found in $AWS_REGION. Creating a new one..."
    aws ec2 create-key-pair --region "$AWS_REGION" --key-name "$KEYNAME" --query 'KeyMaterial' --output text > ~/.ssh/"$KEYNAME".pem
    chmod 400 ~/.ssh/"$KEYNAME".pem
    echo "Key pair $KEYNAME created and saved to ~/.ssh/$KEYNAME.pem"
  fi


  # サブネットID取得
  if [[ "$SUBNETNAME" =~ ^subnet- ]]; then
    # SUBNETNAMEがサブネットIDの場合
    SUBNETID="$SUBNETNAME"
  else
    # SUBNETNAMEがサブネット名の場合
    SUBNETID=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=tag:Name,Values=$SUBNETNAME" --query "Subnets[0].SubnetId" --output text)
    [ -z "$SUBNETID" ] && { echo "Error: Subnet $SUBNETNAME not found"; continue; }
  fi
  echo "SUBNET-ID: ${SUBNETID}"

  # VPC ID取得
  VPC_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$SUBNETID" --query "Subnets[0].VpcId" --output text)

  # セキュリティグループID取得
  SECURITYGROUPIDS=()
  if [ -n "$SECURITYGROUPNAMES" ]; then
    IFS=';' read -r -a SG_NAMES <<< "$SECURITYGROUPNAMES"
    for SG_NAME in "${SG_NAMES[@]}"; do
      if [[ "$SG_NAME" =~ ^sg- ]]; then
        # SG_NAMEがセキュリティグループIDの場合
        SG_ID="$SG_NAME"
      else
        # SG_NAMEがセキュリティグループ名の場合
        SG_ID=$(aws ec2 describe-security-groups \
          --region "$AWS_REGION" \
          --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
          --query "SecurityGroups[0].GroupId" \
          --output text)
        [ -z "$SG_ID" ] && { echo "Error: Security group $SG_NAME not found"; continue; }
      fi
      SECURITYGROUPIDS+=("$SG_ID")
    done
  fi
  echo "SECURITYGROUP-IDS: ${SECURITYGROUPIDS[*]}"

  # タグ定義
  TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=CostDiv,Value=$COST_TAG}]"

  # インスタンス作成
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$IMAGEID" \
    --instance-type "$INSTANCETYPE" \
    --key-name "$KEYNAME" \
    $(if [ ${#SECURITYGROUPIDS[@]} -gt 0 ]; then echo "--security-group-ids ${SECURITYGROUPIDS[*]}"; fi) \
    --subnet-id "$SUBNETID" \
    $(if [ -n "$PRIVATEIPADDRESS" ]; then echo "--private-ip-address $PRIVATEIPADDRESS"; fi) \
    --disable-api-termination \
    --tag-specifications "$TAG_SPEC" \
    --block-device-mappings "[{
      \"DeviceName\":\"$ROOT_DEVICE_NAME\",
      \"Ebs\":{
        \"VolumeSize\":$VOLUMESIZE,
        \"VolumeType\":\"$VOLUMETYPE\",
        \"Encrypted\":true
      }
    }]" \
    --query 'Instances[0].InstanceId' \
    --output text)

  echo "Instance $NAME created successfully in $AWS_REGION"
  echo "Instance ID: $INSTANCE_ID"

  # インスタンスの起動を待つ
  echo "Waiting for instance $INSTANCE_ID to enter 'running' state..."
  for i in {1..10}; do
    STATUS=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)
    if [[ "$STATUS" == "running" ]]; then
      echo "Instance $INSTANCE_ID is now running."
      break
    fi
    echo "Current status: $STATUS. Retrying in 10 seconds..."
    sleep 10
  done

  # rootボリュームにタグ付与
  ROOT_VOLUME_ID=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text)
  aws ec2 create-tags --resources "$ROOT_VOLUME_ID" --tags "Key=Name,Value=$NAME-root" "Key=CostDiv,Value=$COST_TAG"

  # Elastic IP処理
  if [[ "$ALLOCATEELASTICIP" == "TRUE" ]]; then
    ALLOC_ID=$(aws ec2 allocate-address --region "$AWS_REGION" --query 'AllocationId' --output text)
    aws ec2 associate-address --region "$AWS_REGION" --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID"
    aws ec2 create-tags --region "$AWS_REGION" --resources "$ALLOC_ID" --tags "Key=Name,Value=$NAME" "Key=CostDiv,Value=$COST_TAG"
  fi

  # インスタンスの AZ を取得
  INSTANCE_AZ=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)

  echo "Instance AZ: $INSTANCE_AZ"

  # 追加ストレージ処理
  if [[ -n "$ADDITIONALVOLUMESIZES" && "$ADDITIONALVOLUMESIZES" != "null" ]]; then
    IFS=';' read -r -a SIZES <<< "$ADDITIONALVOLUMESIZES"
    IFS=';' read -r -a TYPES <<< "$ADDITIONALVOLUMETYPES"

    for i in "${!SIZES[@]}"; do
      VOL_ID=$(aws ec2 create-volume \
        --region "$AWS_REGION" \
        --availability-zone "$INSTANCE_AZ" \
        --size "${SIZES[$i]}" \
        --volume-type "${TYPES[$i]}" \
        --query 'VolumeId' --output text)

      echo "Created volume: $VOL_ID in $INSTANCE_AZ"

      # ボリュームがavailableになるまで待機
      VOLUME_STATUS="creating"
      while [[ "$VOLUME_STATUS" != "available" ]]; do
        VOLUME_STATUS=$(aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids "$VOL_ID" --query "Volumes[0].State" --output text)
        echo "Volume $VOL_ID status: $VOLUME_STATUS. Waiting 5 seconds..."
        sleep 5
      done

      # 追加デバイス名を動的に設定
      DEVICE_NAME="${ADDITIONAL_DEVICE_PREFIX}$(echo {b..z} | cut -d ' ' -f $((i+1)))"
      echo "Attaching volume $VOL_ID to $DEVICE_NAME"

      aws ec2 attach-volume \
        --region "$AWS_REGION" \
        --instance-id "$INSTANCE_ID" \
        --device "$DEVICE_NAME" \
        --volume-id "$VOL_ID"

      aws ec2 create-tags --resources "$VOL_ID" --tags "Key=Name,Value=$NAME" "Key=CostDiv,Value=$COST_TAG"
    done
  fi

  # IAMロール処理
  if [[ -n "$IAMINSTANCEPROFILE" && "$IAMINSTANCEPROFILE" != "null" ]]; then
    aws ec2 associate-iam-instance-profile \
      --region "$AWS_REGION" \
      --instance-id "$INSTANCE_ID" \
      --iam-instance-profile "Name=$IAMINSTANCEPROFILE"
  fi

  # 終了保護設定
  if [[ "$DISABLEAPITERMINATION" == "TRUE" ]]; then
    aws ec2 modify-instance-attribute --region "$AWS_REGION" --instance-id "$INSTANCE_ID" --disable-api-termination "Value=true"
    echo "Instance $INSTANCE_ID termination protection enabled."
  else
    aws ec2 modify-instance-attribute --region "$AWS_REGION" --instance-id "$INSTANCE_ID" --disable-api-termination "Value=false"
    echo "Instance $INSTANCE_ID termination protection disabled."
  fi

  echo "インスタンス作成完了 $NAME "
  echo "----------------------------------"
done
