
# Phase 1 — AWS Foundations

Self-directed Cloud/DevOps learning project. This document covers the key infrastructure decisions and automation scripts built during Phase 1.

## Identity & Access Management

- **Root account** — MFA enabled, used only for account-level tasks (billing, account settings). Not used day-to-day.
- **IAM user** — created for daily work, MFA enabled, CLI access keys configured.
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

## Security group validation

Tested the difference between security groups and NACLs hands-on rather than just reading about the distinction:

- **Security groups** are stateful — an allowed inbound rule automatically permits the matching response traffic back out, regardless of outbound rules
- **NACLs** are stateless — inbound and outbound must each be explicitly allowed. Allowing inbound port 80 without also allowing outbound traffic on the ephemeral port range (`1024–65535`) causes the connection to silently fail, since the response can't get back out.

Also confirmed that testing an IP-restricted rule (SSH limited to "My IP") only proves anything when tested from a genuinely different network — devices on the same home network share one public IP, so testing between them doesn't validate the restriction. Confirmed the SSH rule correctly refuses connections from mobile data (a different network/IP), while HTTP (open to `0.0.0.0/0`) is correctly reachable from anywhere.

## S3 bucket

Created an S3 bucket with **Block all public access** enabled — kept private by default rather than exposed, since public bucket misconfiguration is a common real-world security incident.

Verified upload/download using the AWS CLI:

```bash
aws s3 cp test-file.txt s3://bucket-name/
aws s3 cp s3://bucket-name/test-file.txt downloaded-copy.txt
```

## GitHub

Pushed lab notes, this documentation, and a `.gitignore` excluding key files, credentials, and future Terraform state files:
```
*.pem
.aws/
.env
*.tfstate
```

## RDS Setup

- **PostgreSQL** RDS instance created via Standard/Full configuration (not Easy create), specifically to control every setting deliberately.
- Burstable instance class `db.t3.micro`, Free tier template.
- Storage autoscaling disabled — deliberate, predictable resource sizing over "let AWS grow it automatically"
- Public access explicitly set to `No`
- Encryption at rest enabled
- Automated backups enabled, short retention
- Password authentication (IAM/Kerberos auth noted as a future consideration for Phase 4 compliance work)

### DB subnet group and AZ requirement

RDS requires a subnet group spanning at least two AZs, even for a single non-Multi-AZ instance — this is why **Private subnet 2** needed correcting into a separate AZ back in Week 2.
- Explicitly chose the instance's AZ (`eu-central-1a`, matching **Private subnet 1**) rather than leaving it to "No preference," to keep app-tier and database co-located and reduce cross-AZ latency.
- **Private subnet 2** exists structurally to satisfy this requirement but currently holds no running resource, since Multi-AZ failover isn't enabled.

### Security group trust chain — tested, not just designed

- `sg-Database` only trusts `sg-AppPrivateSubnet`, not `sg-PublicWeb`, not the internet.
- Discovered mid-task that `sg-AppPrivateSubnet` initially only allowed port 8080 (application traffic) and was missing an SSH rule (port 22, sourced from `sg-PublicWeb`) needed for administrative bastion access — added as a legitimate, permanent part of the design, not a workaround.
- Full chain verified with real connection attempts: successful `psql` connection from the **app-tier private EC2 instance**; confirmed failed/blocked connection attempts from the public instance and from a local laptop outside the VPC entirely.

### Bastion host pattern

**Private instance** has no internet route and can't be reached directly; accessed via SSH hop through the public instance (a "bastion" or "jump box" — standard pattern in real environments).
- Practical connection method: copying the .pem key onto the public instance and using it directly with -i on the second hop, rather than relying on SSH agent forwarding (-A), which showed the key as loaded (ssh-add -l) but still failed authentication for reasons not fully resolved — worth flagging as an open troubleshooting question rather than a fully explained root cause.
- Verified key pair identity directly by comparing the local .pem file's derived public key against AWS's stored key pair record (ssh-keygen -y vs aws ec2 describe-key-pairs --include-public-key) — confirmed an exact match, ruling out a key mismatch before finding the actual fix.

### TLS/SSL connection to RDS

Used AWS's recommended `sslmode=verify-full` connection method with the downloaded `global-bundle.pem` root certificate, rather than a bare unencrypted connection string — verifies both encryption and genuine `RDS endpoint` identity.

### NAT Gateway — discovered organically, not just studied

Needed to install `psql` on the private instance, which requires internet access the private subnet doesn't have by design.
- Built a `NAT Gateway` (Zonal mode, in the public subnet) with an `Elastic IP`, and added a 0.0.0.0/0 → NAT Gateway route to the private subnet's route table, giving outbound-only internet access without exposing the instance to inbound connections.
- Deliberately deleted the NAT Gateway and released the Elastic IP after testing, to conserve free-tier credits, since NAT Gateways bill continuously by the hour regardless of usage — to be rebuilt properly as Terraform code in Phase 2 rather than left running manually.

> **Note:** A NAT Gateway was needed separately, to give the private instance outbound internet access to install psql. Unlike an Internet Gateway, a NAT Gateway lives in the public subnet and only allows traffic initiated from inside the private subnet — the internet can never initiate a connection in, only respond to requests the private instance made first.

## Verifying Unreachability at the Network Layer

Reachability from the app-tier EC2 instance was already confirmed via a successful `psql` connection (see **bastion host**). To properly test the "unreachable from the internet" half of this task, two commands were run from a local machine, outside the VPC entirely.

### DNS resolution check

```bash
nslookup self-learn-database-1.cr2o2y8sack5.eu-central-1.rds.amazonaws.com
```

`nslookup` queries DNS to see what IP address a hostname resolves to. This checks whether the RDS endpoint is even discoverable from the public internet, and what address it points to.

**Result:**

    Address: 10.0.1.132

The hostname resolves — but to `10.0.1.132`, a **private IP** inside the VPC's `10.0.1.0/24` range. This is expected behavior for an RDS instance with "Publicly accessible: No" — AWS never assigns it a real internet-routable IP, only a private one meaningful inside the VPC.

### TCP reachability check

```bash
nc -zv -w 5 self-learn-database-1.cr2o2y8sack5.eu-central-1.rds.amazonaws.com 5432
```

`nc` (netcat) attempts a raw TCP connection to a specific host and port, without needing any application protocol behind it — a direct way to test "is anything reachable here at all," separate from whether PostgreSQL itself would accept the connection.

- `-z` — "zero-I/O mode," just test whether the port is reachable, don't send any data
- `-v` — verbose output
- `-w 5` — timeout after 5 seconds rather than hanging indefinitely

**Result:**

    Ncat: TIMEOUT.

The connection attempt timed out rather than being actively refused. This distinction matters: a **refused** connection means a response came back rejecting the attempt (something reachable said "no"). A **timeout** means no response came back at all — the packet had nowhere to go, because `10.0.1.132` isn't a routable address from outside the VPC.

### What this confirms

RDS's unreachability from the internet is enforced at two independent layers, not one:

1. **Routing/addressing layer** — the database has no real public IP at all; its endpoint resolves to a private address unroutable from outside the VPC. An external client has no path to it, regardless of any firewall rule.
2. **Security group layer** — even from somewhere with a valid route (e.g. another resource inside the VPC), `sg-Database` still only accepts traffic from `sg-AppPrivateSubnet`.

An attacker on the public internet would fail at layer 1 and never even reach the point where layer 2's rules get evaluated — a stronger security posture than relying on the security group alone.

## Automation Scripts

Three Bash scripts were built to automate common AWS operations, replacing manual console clicks with reusable, parameterized commands.

### EC2 instance manager (`ec2-manager.sh`)

Manages EC2 instances by name rather than instance ID, since IDs are easy to mistype and hard to remember.

- **List** — shows all instances with ID, state, and Name tag in a readable table.
- **Start / Stop** — looks up an instance by its Name tag, resolves it to an instance ID via `aws ec2 describe-instances --filters`, then acts on it.
- **Duplicate-name safety** — if more than one instance shares the same Name tag, the script refuses to act and lists all matches instead of guessing which one was intended, since AWS does not enforce Name tag uniqueness.

Usage:
```bash
./ec2-manager.sh list
./ec2-manager.sh start <instance-name>
./ec2-manager.sh stop <instance-name>
```

### S3 backup script (`s3-backup.sh`)

Copies a local directory to S3, timestamping each run so backups don't overwrite one another.

- Generates a timestamp (`date +%Y%m%d-%H%M%S`) and uses it as a unique folder prefix in the destination bucket.
- Uses `aws s3 cp --recursive` to copy the full contents of a source directory.
- Checks the source directory exists before attempting the backup, failing early with a clear error rather than a confusing AWS-side failure.

Usage:
```bash
./s3-backup.sh
```

### Key Bash concepts applied

- **Command substitution** (`$(...)`) — capturing a command's output into a variable, e.g. an instance ID or a timestamp.
- **Variable substitution** (`$VAR`) — reusing captured values across later commands.
- **Functions with arguments** (`$1`, `$2`) — parameterizing scripts instead of hardcoding values.
- **`case` statements** — dispatching to the correct function based on a command-line argument.
- **Conditionals (`if [[ ]]`)** — validating input and failing safely rather than proceeding with bad data.

## Application Load Balancer setup for EC2

### ALB preparation and creation

An ALB requires subnets spanning at least two Availability Zones, same structural rule hit with RDS. Existing setup only had one public subnet (`10.0.1.0/28`, `eu-central-1a`), so a **second public subnet** was needed first. 
Carved `10.0.1.16/28` (the next available, correctly-aligned /28 block after the existing public subnet) and placed it in `eu-central-1b` — the second AZ. Associated it with the same route table as the original public subnet, so it inherited the same `0.0.0.0/0` → Internet Gateway route, making it genuinely public.

Reasoned through the ALB's security group, rather than reusing an existing one. Considered attaching the existing `sg-PublicWeb` directly to the ALB, then recognized the problem: the ALB needs to be the sole internet-facing entry point, while EC2 instances should only trust traffic that has already passed through the ALB — the same tiered-trust principle already applied between `sg-PublicWeb` → `sg-AppPrivateSubnet` → `sg-Database`.
- Created a dedicated **sg-webALB** security group. Inbound: HTTP 80 (and 443) from `0.0.0.0/0` — since the ALB is now the actual public front door.
- Updated `sg-PublicWeb`. Removed the direct `0.0.0.0/0` inbound rule for HTTP/HTTPS. Added a new inbound rule: HTTP 80, source = `sg-webALB` (security group reference) — so EC2 instances now only accept web traffic that's already passed through the load balancer. Kept the `SSH` rule (from a specific IP) unchanged, since administrative access is separate from application traffic.

Created the Application Load Balancer:

- Scheme: Internet-facing.
- VPC: custom VPC.
- Mappings: both public subnets, one per AZ.
- Security group: explicitly deselected the auto-selected, rules-empty default security group, and attached only `sg-webALB`
- Skipped optional service integrations (CloudFront + WAF, standalone WAF) — deliberately out of scope for this task.
- Skipped IPAM for subnet/CIDR assignment — chosen manually instead, consistent with doing the CIDR math by hand throughout this project.

### Created the target group

- Target type: Instances.
- Protocol/port: HTTP : 80, matching Apache's actual listening port.
- Health check path: /
- Protocol version: HTTP/1 — matched to what plain Apache actually speaks (HTTP/2 and gRPC both require explicit backend support Apache doesn't have configured).
- Registered the existing EC2 web server instance as a target.

Selected the target group as the default action during ALB creation, completing the path: internet → ALB (`sg-webALB`) → target group → EC2 instance (`sg-PublicWeb`, now only trusting `sg-webALB`).

### End-to-end verification

ALB's DNS name served the Apache page correctly once "Active". Target health check showed the instance as healthy. Direct access to the EC2 instance's public IP failed once `sg-PublicWeb` no longer trusted `0.0.0.0/0` directly — confirming the ALB is now the sole front door.

## Auto Scaling Group

Recognized that the ALB had only one manually-launched, static EC2 instance registered as a target — no automatic recovery if that instance failed, no ability to scale under load. An ASG solves this by managing instance lifecycle automatically: launching replacements on failure, scaling out under demand, scaling in when idle.

### Launch Template

Built a reusable instance blueprint (web-server-template) rather than relying on manual console clicks each time — the first step toward defining infrastructure as a repeatable specification rather than one-off actions.

- AMI: Amazon Linux 2023, matching the existing manually-built instance
- Instance type: t3.micro
- Key pair: existing EC2-self-learn-login
- Security group: `sg-PublicWeb` — deliberately not `sg-webALB`, since the launch template defines EC2 instances, and each resource must carry the security group representing what it is, not what it talks to. Attaching `sg-webALB` to an EC2 instance would have been the same category error as attaching `sg-Database` to an EC2 instance.
User data script added to automatically install and start Apache on boot, since ASG-launched instances have no human present to configure them by hand:

```bash
#!/bin/bash
dnf update -y
dnf install -y httpd
systemctl start httpd
systemctl enable httpd
echo "<h1>Server from ASG</h1>" > /var/www/html/index.html
```

### ASG creation

- Attached the launch template built above.
- VPC and both public subnets selected, spreading instances across both AZs — same high-availability principle applied throughout this project.
- Attached to the existing target group, connecting the ASG directly to the ALB.
- ELB health checks enabled, in addition to default EC2 status checks — EC2-only checks confirm the OS is running, but can't detect an application-level failure (e.g. Apache crashing while the instance stays "healthy" at the OS level). Enabling ELB health checks means the ASG trusts the target group's / health check result, allowing it to detect and replace instances that are technically running but not actually serving traffic.
- **Desired capacity** 2, minimum 1, maximum 3 — small values appropriate for a learning environment, while still exercising genuine scaling behavior.

#### Evaluated several advanced settings and deliberately left them at default

- ARC Zonal Shift — disabled; a resilience feature for redirecting traffic away from a degraded AZ at real production scale/traffic — not meaningful for a 2–3 instance learning setup.
- EBS DeleteOnTermination — left as default (true); volumes are deleted automatically when the ASG terminates an instance. Appropriate since these are stateless web servers reconfigured fresh via user data on every boot, with no unique data on the local disk — actual persistent state lives in RDS, which has its own independent backup mechanism.
- Instance maintenance policy — left as default; governs replacement sequencing (launch-before-terminate vs. terminate-before-launch) to avoid capacity dips during rolling replacements — a real production concern, not meaningful at this traffic scale.

#### Confirmed the architecture end-to-end

ASG launches instances from the shared template → instances register automatically with the existing target group → ALB routes traffic to whichever instances are currently healthy → unhealthy instances are automatically terminated and replaced, without manual intervention.

### Failover test

An ASG-managed instance was deliberately terminated to test failover behavior. The ASG detected the drop below desired capacity and automatically launched a replacement instance, which passed health checks and was added back to the target group — confirming the self-healing behavior.

### ASG instance replacement influence on traffic

Under normal instance replacement, traffic is unaffected: the ALB simply stops routing to the unhealthy instance and continues distributing across the remaining healthy ones, while the ASG launches a replacement in the background. If all instances became unhealthy simultaneously, there would be a genuine service gap (ALB returns 503) until at least one replacement instance passes health checks — this gap can be minimized (health check tuning, keeping minimum capacity above zero) but not eliminated. 

> **Note:** A more dangerous variant of this scenario was actually encountered during this task: a broken launch template
(**missing public IP**, causing user data to fail) meant every replacement instance failed identically, so the ASG kept replacing unhealthy instances with equally unhealthy ones — a failure mode where automatic recovery alone isn't sufficient without also fixing the underlying template.

### Launch template troubleshooting

Initial ASG instances launched but registered as **Unhealthy** in the target group. Investigation:

- SSH into one instance confirmed Apache was never installed — `sudo cat /var/log/cloud-init-output.log` showed the user data script never completed
- Root cause: the launch template's network settings didn't explicitly enable **auto-assign public IP**, so instances launched without internet access — identical to the private-subnet problem from Week 4, just unintentional this time
- Without a public IP (and no NAT Gateway in place), `dnf update`/`dnf install httpd` in the user data script had no route to the internet and silently failed
- Fixed by creating a new launch template version with **Auto-assign public IP: Enable**, and updating the ASG to use it — new instances then installed Apache successfully and passed health checks.

## Domain Registration & DNS (Route 53)

### AWS payment restriction encountered

Attempted to register a domain directly through Route 53. This failed with `AccessDeniedException: Free Tier accounts are not supported for this service`. Investigation confirmed this is a real, documented account-level restriction — Route 53 domain registration requires a genuine chargeable payment method on file and explicitly cannot be completed using free-tier credits, regardless of account balance.

Domain **transfer** into Route 53 was considered as an alternative, but ruled out: a transfer is itself a billable registration event from AWS's perspective, and would hit the same restriction. Transfers also carry independent friction (60-day domain age minimum, EPP authorization codes, 5–7 day processing time) unrelated to the payment issue.

### Solution: decoupled registrar and DNS provider

Registered `jankodev.site` through a Romanian domain registrar instead, and used Route 53 purely as the DNS provider — a standard, common real-world pattern where the company handling domain ownership/registration is separate from the company answering DNS queries for it.

- **Registrar** (Romanian provider) — owns the registration record, handles renewal/billing for the domain itself
- **DNS provider** (Route 53) — answers "what does this domain point to," entirely independent of who registered it

This required no AWS billing changes and fully sidestepped the payment restriction, while still delivering genuine, real public DNS resolution — a stronger result than working around the task with a non-resolving placeholder domain.

### Hosted zone and delegation

Created a **Public Hosted Zone** in Route 53 for `jankodev.site` (Private Hosted Zone was considered and rejected — private zones only resolve inside a VPC, which doesn't meet the requirement of public internet resolution).

Route 53 automatically provisioned two records on zone creation:
- **NS** — the four authoritative nameservers for this zone
- **SOA** — zone metadata (primary nameserver, refresh/retry timing) managed automatically by Route 53

Copied the four `awsdns` nameservers into the Romanian registrar's nameserver settings, delegating DNS authority for the domain to Route 53. First delegation attempt returned a registrar-side error (`domain delegation already in progress`), which resolved itself after a short wait — the change had actually been accepted despite the initial error message.

### Alias record

Created an **A record with Alias enabled**, pointing the domain root at the ALB's dual-stack DNS name (`dualstack.web-alb-*.eu-central-1.elb.amazonaws.com`). Alias records are a Route 53-specific mechanism for pointing at AWS-managed resources like an ALB — necessary because, unlike a static EC2 IP, an ALB's underlying IPs are not fixed and can change; Alias records resolve dynamically rather than pointing at a hardcoded address.

### Verification

```bash
nslookup -type=NS jankodev.site
```
Confirmed all four `awsdns` nameservers resolving correctly, proving delegation had propagated.

```bash
curl -I http://jankodev.site
```
Returned `200 OK` directly from Apache — confirming the full chain end to end:

**Romanian registrar → delegated nameservers → Route 53 hosted zone → Alias A record → ALB → target group → EC2 instance**

## CloudFront Distribution with S3 Origin

### Setup

Created a fully private S3 bucket (initially `janko-static-site`, later rebuilt as `static-site-janko` — see troubleshooting below) with **Block all public access** enabled, no static website hosting mode, and a simple `index.html` uploaded. Verified the bucket was genuinely private before touching CloudFront:

```bash
curl -I https://<bucket>.s3.eu-central-1.amazonaws.com/index.html
```
Returned `403 AccessDenied` as expected — confirming a clean, non-public baseline before configuring any CDN access.

Created a CloudFront distribution with this bucket as the origin, using **Origin Access Control (OAC)** rather than the deprecated Origin Access Identity (OAI) — the current AWS-recommended mechanism for granting a private S3 bucket read access to a specific CloudFront distribution only. CloudFront auto-generated and applied the required bucket policy, scoping `s3:GetObject` to the exact distribution ARN via a `SourceArn` condition — the same reference-based trust pattern used throughout this project for security groups.

### Troubleshooting: persistent 403 despite correct configuration

Initial testing returned `403 AccessDenied` (`server: AmazonS3`, `x-cache: Error from cloudfront`) — indicating CloudFront was reaching the origin, and S3 itself was rejecting the request.

Methodically verified every layer of the CloudFront ↔ S3 trust chain, all of which checked out as individually correct:
- Bucket policy content, `Resource` ARN, and `SourceArn` condition
- AWS account ID match between policy and caller identity
- OAC signing configuration (`sigv4`, `always`, origin type `s3`)
- Origin domain format (regional REST endpoint, not the legacy website-hosting endpoint, which doesn't support OAC)
- Default cache behavior's target origin ID
- Bucket ownership controls (`BucketOwnerEnforced`) and object ACLs
- Encryption type (SSE-S3, not SSE-KMS, ruling out a separate KMS key-policy permission layer)
- Direct `aws s3 cp` download using admin credentials, confirming the object and bucket were genuinely fine outside of CloudFront

With every individual piece correct, rebuilt the distribution and OAC entirely from scratch (deleted, waited for full removal, recreated) to rule out stale internal CloudFront state — the failure persisted identically on the rebuilt distribution.

**Root cause, found by testing the literal object path instead of the bucket root:**
```bash
curl -I https://<distribution>.cloudfront.net/index.html   # → 200 OK
curl -I https://<distribution>.cloudfront.net/             # → 403 AccessDenied
```
The distribution's **Default Root Object** field was empty, despite selecting `index.html` during creation. Without it, a request to `/` has no defined object to resolve to — CloudFront passes the request through essentially unresolved, and S3 denies it. Because the OAC policy grants only `s3:GetObject` (not `s3:ListBucket`), S3 has no way to distinguish "this object doesn't exist" from "you're not allowed to see this," and returns `AccessDenied` for both — the same error a genuine permissions failure would produce.

**Fix:** set Default Root Object to `index.html` via the console (General tab → Edit), redeployed, and confirmed root path access returned `200 OK`.

### Key lesson

A `403 AccessDenied` from an S3 origin behind CloudFront does not always indicate a permissions problem. Testing the exact object path directly (bypassing root-object resolution) isolates whether the issue is genuinely a trust/policy failure or simply a missing/unresolved object — a fast, decisive diagnostic step that would have shortened this investigation considerably if applied earlier.

## HTTPS via ACM — CloudFront and ALB Certificates

### Two certificates, two regions

Task required attaching a TLS certificate to both CloudFront and the ALB. These cannot share a single certificate object: ACM certificates are region-scoped, and **CloudFront only accepts certificates issued in `us-east-1`** regardless of where other resources live, while an ALB's certificate must be issued in the ALB's own region (`eu-central-1`). Two separate certificate requests were made for the same domain (`jankodev.site`) — one per region — rather than one shared certificate, which isn't technically possible across regions in ACM.

### Validation troubleshooting

Both certificates sat in `PENDING_VALIDATION` for roughly 24 hours with no progress. Investigation via `aws acm describe-certificate` showed both requests expected the **same DNS validation CNAME record** (identical name and value for both, despite being separate certificate objects in separate regions) — but `aws route53 list-resource-record-sets` confirmed the record had never actually been created in the hosted zone, despite requesting the certificates through a flow that should have offered automatic Route 53 record creation.

Created the missing CNAME record manually:
```bash
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --change-batch '{...}'
```
Both certificates validated and moved to `ISSUED` status within minutes of the record going live — confirming the record's absence, not propagation timing, had been the actual blocker.

### ALB — HTTPS listener

Added a new listener to the ALB:
- **HTTPS : 443**, forwarding to the existing target group, using the `eu-central-1` certificate

Modified the existing **HTTP : 80** listener's action from "forward" to **redirect to HTTPS**, using a `301 Moved Permanently` status code (not `302`) — a 301 correctly signals a permanent move, matches how browsers cache and handle the redirect, and reflects that plain HTTP is not meant to serve real content going forward, only redirect. Redirect target preserved the original host/path/query dynamically (`#{host}`, `#{path}`, `#{query}`) rather than hardcoding a fixed destination.

### Security group update

`sg-webALB`'s existing rule only covered HTTP:80 — a separate, explicit HTTPS:443 inbound rule (source `0.0.0.0/0`) was required, since security group rules are scoped per port, not per "web traffic" generally. Adding the HTTPS listener alone did not open network-level access; the security group had to be updated independently.

### Verification

```bash
curl -I http://jankodev.site    # → 301, redirects to HTTPS
curl -I https://jankodev.site   # → 200 OK, served over TLS
```

> **Note:** Days before this verification, the ASG had been deliberately scaled to zero instances as a cost-saving measure during the CloudFront/S3 troubleshooting stretch. This produced a `503` from the ALB (`server: awselb/2.0`, no healthy targets) when first testing HTTPS — a reminder that ALB/HTTPS configuration and target availability are independent concerns; a correctly configured listener and certificate still return nothing useful without at least one healthy target behind it. Scaling the ASG back to a minimum of 1 resolved it.

### CloudFront — custom domain and certificate

The `us-east-1` certificate initially requested only covered `jankodev.site`, not `static.jankodev.site` — attempting to add the alternate domain name failed with a clear CloudFront validation error confirming certificates only cover the exact names they were issued for (no implicit subdomain coverage without a wildcard). Requested a second, purpose-specific `us-east-1` certificate for `static.jankodev.site` rather than a wildcard, consistent with the least-privilege reasoning applied earlier when choosing specific-domain certificates over `*.jankodev.site`.

DNS validation for this certificate again required a manually created Route 53 CNAME record — the automatic record-creation option did not fire a second time, confirming this as a recurring, not one-off, gap in the certificate request flow rather than a fluke.

Once issued, attached the certificate to the CloudFront distribution as an **Alternate Domain Name (CNAME)**: `static.jankodev.site`. Created a matching **Alias A record** in Route 53, pointing `static.jankodev.site` at the CloudFront distribution — the same alias mechanism used for the ALB, just targeting a different AWS-managed resource.

### Final verification — both paths

```bash
curl -I https://jankodev.site           # → ALB, dynamic content, 200 OK
curl -I https://static.jankodev.site    # → CloudFront + S3, static content, 200 OK
```

Both domains now resolve over HTTPS with valid, trusted certificates — `jankodev.site` serving the dynamic ASG-backed application through the ALB, and `static.jankodev.site` serving static content through CloudFront and S3 — two distinct, correctly isolated architectures sharing one parent domain.

## Testing HTTPS End-to-End

With certificates issued and attached, verified the complete client-facing HTTPS path using `curl`'s verbose output rather than just trusting the configuration on paper.

### Target group protocol — confirming where TLS terminates

```bash
aws elbv2 describe-target-groups --query 'TargetGroups[*].[TargetGroupName,Protocol,Port]' --output table
```

Confirmed the target group communicates over plain **HTTP:80** internally. This means TLS terminates at the ALB — the client-to-ALB leg is fully encrypted, while the ALB-to-instance leg runs as plain HTTP within the VPC, never exposed to the public internet. This is standard TLS termination at the load balancer, distinct from end-to-end re-encryption (which would require a certificate on the instance itself, not implemented here).

### Certificate validity

```bash
curl -v https://jankodev.site 2>&1 | grep -A 5 "Server certificate"
```

Confirmed:

    subject: CN=jankodev.site
    issuer: C=US; O=Amazon; CN=Amazon RSA 2048 M01
    SSL certificate verified via OpenSSL.

A genuine, trusted certificate — correct domain in the subject, verified without warnings.

### Full request/response cycle

```bash
curl -Iv https://jankodev.site 2>&1 | grep -E "HTTP/|subject:|issuer:|SSL certificate"
```

Returned `HTTP/2 200`, negotiated over TLS, confirming the entire chain — client → ALB (HTTPS, valid cert) → target group (HTTP) → healthy EC2 instance — works end to end.

### HTTP → HTTPS redirect

```bash
curl -I http://jankodev.site
```

Returned `301 Moved Permanently` with `Location: https://jankodev.site/` — confirming plain HTTP requests are correctly upgraded rather than served directly.

### Summary

| Check                 | Result                                           |
|-----------------------|--------------------------------------------------|
| Certificate validity  | Trusted, correct CN, no warnings                 |
| TLS termination point | ALB (target group remains plain HTTP internally) |
| HTTPS response        | `200 OK` over HTTP/2                             |
| HTTP → HTTPS redirect | `301`, dynamic host/path preserved               |


