#!/bin/bash

VPC_CIDR="10.0.1.0/24"
echo "My VPC CIDR is: $VPC_CIDR"
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
echo "Created VPC with ID: $VPC_ID"
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=test_vpc
aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].Tags'
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/28 --availability-zone eu-central-1a --query 'Subnet.SubnetId' --output text)
echo "$SUBNET_ID"
SG_ID=$(aws ec2 create-security-group --group-name PublicWeb --description "web tier" --vpc-id $VPC_ID --query 'GroupId' --output text)
echo "Created security group: $SG_ID"
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0
