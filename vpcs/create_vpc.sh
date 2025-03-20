#!/bin/bash

set -e

# コマンドライン引数からCSVファイル名を取得
if [ $# -ne 1 ]; then
    echo "Usage: $0 <csv-file>"
    exit 1
fi

CSV_FILE="$1"

# ヘッダー行を読み飛ばす
HEADER=$(head -n 1 "$CSV_FILE")

# 2行目以降（実データ）を処理
tail -n +2 "$CSV_FILE" | while IFS=, read -r REGION NAME IMAGEID INSTANCETYPE KEYNAME SUBNETNAME SECURITYGROUPNAMES PRIVATEIPADDRESS DISABLEAPITERMINATION COST_TAG VOLUMESIZE VOLUMETYPE ALLOCATEELASTICIP ADDITIONALVOLUMESIZES ADDITIONALVOLUMETYPES IAMINSTANCEPROFILE OSTYPE
do
    echo "Instance $NAME setup start in region $REGION"

    # AWSリージョンを設定
    AWS_REGION="$REGION"

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
    echo "Root Device Name: $ROOT_DEVICE_NAME"
    echo "Additional Device Prefix: $ADDITIONAL_DEVICE_PREFIX"

    # キーペア確認
    if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEYNAME" &> /dev/null; then
        echo "Error: Key pair $KEYNAME not found in region $AWS_REGION"
        continue
    fi

    # サブネットID取得
    if [[ "$SUBNETNAME" =~ ^subnet- ]]; then
        SUBNETID="$SUBNETNAME"
    else
        SUBNETID=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=tag:Name,Values=$SUBNETNAME" --query "Subnets[0].SubnetId" --output text)
        [ -z "$SUBNETID" ] && { echo "Error: Subnet $SUBNETNAME not found in region $AWS_REGION"; continue; }
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
                SG_ID="$SG_NAME"
            else
                SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
                    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
                    --query "SecurityGroups[0].GroupId" --output text)
                [ -z "$SG_ID" ] && { echo "Error: Security group $SG_NAME not found in region $AWS_REGION"; continue; }
            fi
            SECURITYGROUPIDS+=("$SG_ID")
        done
    fi
    echo "SECURITYGROUP-IDS: ${SECURITYGROUPIDS[*]}"

    # タグ定義
    TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=CostDiv,Value=$COST_TAG}]"

    # インスタンス作成
    INSTANCE_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
        --image-id "$IMAGEID" \
        --instance-type "$INSTANCETYPE" \
        --key-name "$KEYNAME" \
        $(if [ ${#SECURITYGROUPIDS[@]} -gt 0 ]; then echo "--security-group-ids ${SECURITYGROUPIDS[*]}"; fi) \
        --subnet-id "$SUBNETID" \
        $(if [ -n "$PRIVATEIPADDRESS" ]; then echo "--private-ip-address $PRIVATEIPADDRESS"; fi) \
        --disable-api-termination \
        --tag-specifications "$TAG_SPEC" \
        --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE_NAME\",\"Ebs\":{\"VolumeSize\":$VOLUMESIZE,\"VolumeType\":\"$VOLUMETYPE\",\"Encrypted\":true}}]" \
        --query 'Instances[0].InstanceId' --output text)

    echo "Instance $NAME created successfully in region $AWS_REGION"
    echo "Instance ID: $INSTANCE_ID"

    # rootボリュームにタグ付与
    ROOT_VOLUME_ID=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text)
    aws ec2 create-tags --region "$AWS_REGION" --resources "$ROOT_VOLUME_ID" --tags "Key=Name,Value=$NAME-root" "Key=CostDiv,Value=$COST_TAG"

    echo "Instance $NAME setup complete in region $AWS_REGION"
    echo "----------------------------------"

done

