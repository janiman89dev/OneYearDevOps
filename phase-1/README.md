
# Phase 1 — AWS Foundations

Self-directed Cloud/DevOps learning project. This document covers the key infrastructure decisions made during Phase 1, weeks 1–3.

## Identity & Access Management

- **Root account** — MFA enabled, used only for account-level tasks (billing, account settings). Not used day-to-day.
- **IAM user** (`tyutyejanko`) — created for daily work, MFA enabled, CLI access keys configured.
- Attached policies: `AdministratorAccess`, `IAMUserChangePassword` (allows the user to change their own password without admin intervention)

## VPC & Subnet Design

Custom VPC with one public and two private subnets, replacing the AWS default VPC.

- **VPC CIDR:** `10.0.1.0/24`
- **Subnet size:** `/28` each — chosen deliberately over a larger block since this environment only needs a handful of resources per tier (right-sizing rather than over-provisioning). Each subnet has **11 usable IPs**.

| Subnet    | CIDR            | Range         | AZ            |
|-----------|-----------------|---------------|---------------|
| Public    | `10.0.1.0/28`   | `.0`–`.15`    | eu-central-1a |
| Private 1 | `10.0.1.128/28` | `.128`–`.143` | eu-central-1a |
| Private 2 | `10.0.1.144/28` | `.144`–`.159` | eu-central-1b |

**Purpose per subnet:**
- Public → internet-facing resources (web tier)
- Private 1 → internal resources
- Private 2 → separate AZ, required for RDS multi-AZ subnet groups

> **Note:** Private subnet 2 was initially created in the same AZ as Private subnet 1. This was corrected before Week 4, since RDS multi-AZ subnet groups require private subnets to span at least two distinct AZs.

### Internet routing

- **Public subnet** — has a route to an Internet Gateway (`0.0.0.0/0 → IGW`). This route is what actually makes it "public" — the label itself is just convention.
- **Private subnets** — no internet route currently exists. A NAT Gateway will be added in Week 4, giving outbound-only internet access without exposing these subnets to inbound connections.

## Security Groups

Three security groups form a layered three-tier trust chain — each tier can only be reached by the tier directly before it.

| Security Group   | Inbound Rule    |         Source         |
|------------------|-----------------|------------------------|
| PublicWeb        | HTTP 80         | `0.0.0.0/0`            |
| PublicWeb        | HTTPS 443       | `0.0.0.0/0`            |
| PublicWeb        | SSH 22          | Admin IP               | 
| AppPrivateSubnet | Custom TCP 8080 | `sg-PublicWeb`         |
| Database         | PostgreSQL 5432 | `sg-AppPrivateSubnet`  |

1. **PublicWeb** — 3 inbound rules, default outbound. HTTP (80) and HTTPS (443) open to the internet; SSH (22) restricted to a single defined IP for administrator access.
2. **AppPrivateSubnet** — 1 inbound rule, default outbound. Custom TCP 8080, allowed only from `sg-PublicWeb`.
3. **Database** — 1 inbound rule, default outbound. PostgreSQL 5432, allowed only from `sg-AppPrivateSubnet`. Traffic must already have passed through AppPrivateSubnet on port 8080 to reach the database.

**Key principles:**
- Security groups are **default-deny** — every rule is an explicit permission; there is no "deny" rule. Everything not listed is blocked.
- Access is controlled by **security group references, not IP addresses** — rules dictate traffic based on group membership, not source IP (except the SSH rule, which is intentionally IP-restricted for administrator access).

## EC2 instance

Launched an Amazon Linux 2023 `t3.micro` instance into the public subnet, with `sg-PublicWeb` attached and a public IP auto-assigned.

- Connected via SSH using a downloaded key pair (`chmod 400` required — SSH refuses overly permissive key file permissions)
- Installed Apache (`httpd`) manually, without automation, to understand each step before automating it in Phase 2
- Verified the instance serves content on port 80 and is reachable from outside the home network

> **Note:** CLI-based instance management (start/stop) requires AWS CLI credentials, which weren't configured until this point in the roadmap. This surfaced a sequencing gap — CLI setup was originally scheduled for Week 5, but is a basic prerequisite that should happen much earlier. Credentials were configured ahead of schedule to unblock this and the S3 task below.

### Security group validation

Tested the difference between security groups and NACLs hands-on rather than just reading about the distinction:

- **Security groups** are stateful — an allowed inbound rule automatically permits the matching response traffic back out, regardless of outbound rules
- **NACLs** are stateless — inbound and outbound must each be explicitly allowed. Allowing inbound port 80 without also allowing outbound traffic on the ephemeral port range (`1024–65535`) causes the connection to silently fail, since the response can't get back out.

Also confirmed that testing an IP-restricted rule (SSH limited to "My IP") only proves anything when tested from a genuinely different network — devices on the same home network share one public IP, so testing between them doesn't validate the restriction. Confirmed the SSH rule correctly refuses connections from mobile data (a different network/IP), while HTTP (open to `0.0.0.0/0`) is correctly reachable from anywhere.

### S3 bucket

Created an S3 bucket with **Block all public access** enabled — kept private by default rather than exposed, since public bucket misconfiguration is a common real-world security incident.

Verified upload/download using the AWS CLI:
```bash
aws s3 cp test-file.txt s3://bucket-name/
aws s3 cp s3://bucket-name/test-file.txt downloaded-copy.txt
```

### GitHub

Pushed lab notes, this documentation, and a `.gitignore` excluding key files, credentials, and future Terraform state files:
```
*.pem
.aws/
.env
*.tfstate
```
