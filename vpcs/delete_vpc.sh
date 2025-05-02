#!/bin/bash

# 設定
EC2_VPC_TAG_NAME='handson-cli-vpc'
AWS_DEFAULT_REGION='ap-northeast-1' # 必要に応じて変更

# VPC IDの取得
EC2_VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${EC2_VPC_TAG_NAME}" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ -z "$EC2_VPC_ID" ]; then
  echo "指定されたVPCが見つかりません。"
  exit 1
fi

echo "削除を開始します: VPC ID ${EC2_VPC_ID}"

# NATゲートウェイの削除
echo "NATゲートウェイを削除中..."
NAT_GATEWAY_IDS=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${EC2_VPC_ID}" \
  --query 'NatGateways[*].NatGatewayId' \
  --output text)

for NAT_ID in $NAT_GATEWAY_IDS; do
  aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID
  echo "NATゲートウェイの削除を待機中..."
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_ID
done

# Elastic IPの解放
echo "Elastic IPを解放中..."
ALLOCATION_IDS=$(aws ec2 describe-addresses \
  --filters "Name=domain,Values=vpc" "Name=tag:Name,Values=${EC2_VPC_TAG_NAME}-*" \
  --query 'Addresses[*].AllocationId' \
  --output text)

for ALLOC_ID in $ALLOCATION_IDS; do
  aws ec2 release-address --allocation-id $ALLOC_ID
done

# サブネットの削除
echo "サブネットを削除中..."
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${EC2_VPC_ID}" \
  --query 'Subnets[*].SubnetId' \
  --output text)

for SUBNET_ID in $SUBNET_IDS; do
  aws ec2 delete-subnet --subnet-id $SUBNET_ID
done

# ルートテーブルの削除
echo "ルートテーブルを削除中..."
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${EC2_VPC_ID}" \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
  --output text)

for RT_ID in $ROUTE_TABLE_IDS; do
  aws ec2 delete-route-table --route-table-id $RT_ID
done

# インターネットゲートウェイのデタッチと削除
echo "インターネットゲートウェイをデタッチして削除中..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${EC2_VPC_ID}" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

if [ "$IGW_ID" != "None" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id ${EC2_VPC_ID}
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
fi

# VPCの削除
echo "VPCを削除中..."
aws ec2 delete-vpc --vpc-id ${EC2_VPC_ID}

echo "全てのリソースの削除が完了しました。"

