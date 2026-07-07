# Main AWS CLI Commands — Phase 1

## 1. Create an IAM user
```bash
aws iam create-user --user-name <username>
```

## 2. Create IAM access keys for CLI
```bash
aws iam create-access-key --user-name <username>
```

## 3. Create a VPC
```bash
aws ec2 create-vpc --cidr-block <cidr-block>
```

## 4. Create a VPC subnet
```bash
aws ec2 create-subnet --vpc-id <vpc-id> --cidr-block <subnet-cidr>
```

## 5. Create a VPC security group
```bash
aws ec2 create-security-group --group-name <group-name> --description "<description>" --vpc-id <vpc-id>
```

## 6. Launch an EC2 instance
```bash
aws ec2 run-instances --image-id <ami-id> --count 1 --instance-type <instance-type> --key-name <key-pair-name> --security-group-ids <security-group-id> --subnet-id <subnet-id>
```

## 7. SSH into an EC2 instance
```bash
ssh -i <path-to-private-key> <username>@<public-ip-or-dns>
```

## 8. Create an S3 bucket
```bash
aws s3 mb s3://<bucket-name>
```
