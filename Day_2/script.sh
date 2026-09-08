#!/usr/bin/env bash
###############################################################################
# SwiftCart — Day 2: Global Edge Delivery, Unified Routing & Persistent Storage
# Builds ON TOP of the Day 1 stack (VPCs, ALB, EC2, TGW must already exist).
#
# What this provisions (every console step from the Day 2 guide):
#   - S3 static-assets bucket (block-all-public-access ON) + index.html upload
#   - CloudFront distribution with two origins and Layer-7 routing:
#       default  /*        -> S3   (OAC, CachingOptimized, redirect-to-https)
#       /api/*  /checkout  -> ALB  (CachingDisabled, AllViewer, no cache)
#       (also /product/* and /health -> ALB so the Day 1 app is reachable)
#   - S3 bucket policy locking read access to this distribution only (OAC)
#   - EFS shared file system + SG-EFS-Mount + mount targets in both AZ subnets,
#       mounted on the Web Portal at /var/www/swiftcart/shared_uploads
#   - gp3 EBS volume (50 GiB / 3000 IOPS / 125 MB/s), attached to the Inventory
#       instance, formatted XFS, mounted at /mnt/inventory_cache
#
# The OS-level mount/format steps run over the bastion via SSH using the
# ProxyCommand form (explicit identity on both hops, absolute key path). Set
# DO_OS_MOUNTS=false to skip them and print the equivalent manual commands.
#
# PREREQUISITES
#   - Day 1 stack present (this script discovers it by tag; it aborts if missing)
#   - Same host/creds you used for Day 1 (needs swiftcart-key.pem for the SSH
#     mount step, and this host's IP allowed on the bastion). Missing CLI tools
#     are auto-installed. Credentials via instance profile or `aws configure`.
#
# USAGE
#   chmod +x swiftcart-day2-provision.sh
#   ./swiftcart-day2-provision.sh            # interactive: approve each command
#   ./swiftcart-day2-provision.sh -y         # non-interactive: auto-approve all
#   ./swiftcart-day2-provision.sh --help     # show flags and env overrides
#
# INTERACTIVE CONSENT (build path)
#   Every RESOURCE-CREATING or MUTATING step — AWS API calls AND the SSH-driven
#   OS format/mount commands — is printed verbatim and must be confirmed with
#   'y' / 'Y' before it runs. Read-only describe/list/get/wait calls, local tool
#   installs, and local /tmp file prep run without prompting. Prompts are written
#   to the controlling terminal (/dev/tty), so they survive command substitution
#   ( VAR=$(...) ), process substitution and output capture. Declining a
#   provisioning command aborts the run; declining an OS mount step just skips it
#   and the manual commands are printed instead.
#   Pass -y / --yes (or set ASSUME_YES=true) to auto-approve every prompt —
#   commands are still printed before they execute:
#     ./swiftcart-day2-provision.sh -y
#     ASSUME_YES=true ./swiftcart-day2-provision.sh
#
# IDEMPOTENT: every resource is looked up before creation and reused. Re-run to
# converge. CloudFront takes ~10-15 min to deploy after creation (set
# WAIT_CLOUDFRONT=true to block until deployed). Resource IDs -> swiftcart-day2-state.env
#
# COST WARNING: CloudFront, EFS, and a 50 GiB gp3 volume bill continuously (on
# top of the Day 1 NAT/TGW/ALB). Use ./swiftcart-day2-teardown.sh when finished.
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
REGION="${REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-swiftcart-key}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-true}"
DO_OS_MOUNTS="${DO_OS_MOUNTS:-true}"          # SSH into the instances to format/mount storage
WAIT_CLOUDFRONT="${WAIT_CLOUDFRONT:-false}"   # block until the CDN finishes deploying
ASSUME_YES="${ASSUME_YES:-false}"             # true = auto-approve every consent prompt
EBS_SIZE_GIB="${EBS_SIZE_GIB:-50}"
EBS_IOPS="${EBS_IOPS:-3000}"
EBS_THROUGHPUT="${EBS_THROUGHPUT:-125}"
PROJECT="SwiftCart"

# AWS-managed CloudFront policy IDs (stable across all accounts)
CACHE_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"   # CachingOptimized
CACHE_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"    # CachingDisabled
ORP_ALLVIEWER="216adef6-5c7f-47e4-b989-5492eafa07d3"     # Managed-AllViewer origin request policy

export AWS_DEFAULT_REGION="$REGION"
STATE_FILE="./swiftcart-day2-state.env"
KEY_PEM="${KEY_NAME}.pem"
KEY_FILE="$PWD/$KEY_PEM"    # absolute path — used verbatim in the SSH commands below

# ─────────────────────────────────────────────────────────────────────────────
# CLI flags  (override the CONFIG defaults above)
# ─────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
Usage: ${0##*/} [-y|--yes] [-h|--help]

  -y, --yes     Non-interactive run: every command is still printed before it
                executes, but all consent prompts are auto-approved and no y/N
                prompt is shown (equivalent to ASSUME_YES=true).
  -h, --help    Show this help and exit.

Environment overrides (all optional): REGION, KEY_NAME, AUTO_INSTALL_DEPS,
DO_OS_MOUNTS, WAIT_CLOUDFRONT, EBS_SIZE_GIB, EBS_IOPS, EBS_THROUGHPUT, ASSUME_YES.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)   ASSUME_YES="true" ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    -*)         printf '\033[1;31m[FATAL] Unknown option: %s\033[0m\n' "$1" >&2; usage >&2; exit 2 ;;
    *)          printf '\033[1;31m[FATAL] Unexpected argument: %s\033[0m\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────────────────────
# Helpers (same style as Day 1)
# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }
record() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

# ─────────────────────────────────────────────────────────────────────────────
# Interactive consent  (build path — declining a provisioning command aborts)
# ─────────────────────────────────────────────────────────────────────────────
# Every RESOURCE-CREATING / MUTATING command is echoed exactly and must be
# approved with 'y' / 'Y'. Prompts/echoes go to the controlling terminal
# (/dev/tty), so they survive command substitution ( VAR=$(...) ), process
# substitution and 2>&1 capture used by the wrappers below.
C_CMD=$'\033[1;35m'
C_OFF=$'\033[0m'

# Write a message to the controlling terminal (falls back to stderr if no tty).
_msg_tty() {
  if [[ -w /dev/tty ]]; then printf '%s' "$1" >/dev/tty
  else printf '%s' "$1" >&2
  fi
}

# Render an argv as a readable, copy-pasteable command line. Any argument that
# is empty or contains shell-special characters is single-quoted; embedded
# single quotes are escaped ( ' -> '\'' ) so tag specs / JSON args render right.
_render_cmd() {
  local a out="" esc sq="'"
  for a in "$@"; do
    case "$a" in
      ''|*[!A-Za-z0-9_./:=@%+,-]*)
        esc=${a//$sq/$sq\\$sq$sq}
        out+="$sq$esc$sq " ;;
      *) out+="$a " ;;
    esac
  done
  printf '%s' "${out% }"
}

# Ask the user to approve the already-printed command. Returns 0 to proceed.
_consent() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    _msg_tty "    (auto-approved via -y / ASSUME_YES)"$'\n'; return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    printf '\033[1;33m[warn]\033[0m %s\n' "No TTY to read consent and ASSUME_YES!=true — refusing to continue." >&2
    return 1
  fi
  local reply=""
  _msg_tty "    Proceed with the above command? [y/N] "
  read -r reply </dev/tty || true
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# _confirm_cmd <argv...> : print the exact command and ask y/Y. Does NOT run it.
# Declining aborts the whole script (die). Use inside wrappers that must capture
# the command's own stdout/stderr themselves.
_confirm_cmd() {
  _msg_tty $'\n'"${C_CMD}\$ $(_render_cmd "$@")${C_OFF}"$'\n'
  _consent || die "Aborted by user (declined the command above)."
}

# confirm_run <argv...> : print the command, ask y/Y, then execute it. Caller
# redirections/pipes apply to the command; the prompt goes to /dev/tty. Safe
# inside VAR=$(confirm_run ...) and < <(confirm_run ...) — only stdout is captured.
confirm_run() { _confirm_cmd "$@"; "$@"; }

get_id() {  # get_id "<describe cmd + filters>" "<jmespath>"   READ-ONLY — never gated
  local out; out=$(eval "$1 --query '$2' --output text" 2>/dev/null) || out=""
  [ "$out" = "None" ] && out=""
  printf '%s' "$out"
}
ensure_ingress() {  # idempotent SG ingress. MUTATING — gated (prompted once).
  _confirm_cmd aws ec2 authorize-security-group-ingress "$@"
  local out
  if out=$(aws ec2 authorize-security-group-ingress "$@" 2>&1); then return 0; fi
  case "$out" in *Duplicate*) return 0 ;; esac
  printf '%s\n' "$out" >&2; return 1
}
wait_state() {  # wait_state "<describe cmd>" "<jmespath>" "<target>"   READ-ONLY — never gated
  local desc="$1" query="$2" target="$3" st
  while true; do
    st=$(eval "$desc --query '$query' --output text" 2>/dev/null || echo "pending")
    [ "$st" = "$target" ] && return 0
    case "$st" in error|failed|deleted) die "resource entered '$st' state" ;; esac
    sleep 10
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 0. Preflight + dependency install (mirrors Day 1) — local tooling, NOT gated
# ─────────────────────────────────────────────────────────────────────────────
log "Preflight checks"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
install_deps() {
  local pkgs=()
  command -v jq >/dev/null || pkgs+=(jq)
  command -v curl >/dev/null || pkgs+=(curl)
  command -v unzip >/dev/null || pkgs+=(unzip)
  if [ "${#pkgs[@]}" -gt 0 ]; then
    command -v apt-get >/dev/null || die "missing ${pkgs[*]} and no apt-get — install manually"
    log "Installing packages: ${pkgs[*]}"
    $SUDO apt-get update -y -qq
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  fi
  if ! command -v aws >/dev/null; then
    log "Installing AWS CLI v2…"
    local url tmp
    case "$(uname -m)" in
      x86_64)  url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
      aarch64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
      *) die "unsupported arch $(uname -m)" ;;
    esac
    tmp="$(mktemp -d)"; curl -fsSL "$url" -o "$tmp/a.zip"; unzip -q "$tmp/a.zip" -d "$tmp"
    $SUDO "$tmp/aws/install" --update; rm -rf "$tmp"; hash -r
  fi
}
[ "$AUTO_INSTALL_DEPS" = "true" ] && install_deps
for b in aws jq curl; do command -v "$b" >/dev/null || die "'$b' not on PATH"; done
aws sts get-caller-identity >/dev/null 2>&1 || die "No usable AWS credentials"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ok "Account $ACCOUNT_ID / region $REGION"

echo "# SwiftCart Day2 state — generated $(date)" > "$STATE_FILE"
record REGION "$REGION"
record KEY_FILE "$KEY_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Discover the Day 1 stack (fail clearly if it isn't there) — READ-ONLY
# ─────────────────────────────────────────────────────────────────────────────
log "Discovering Day 1 resources"
VPC_A=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-VPC-A-Public" "Vpcs[0].VpcId")
[ -z "$VPC_A" ] && die "Day 1 VPC A not found — run the Day 1 script first."
SUB_A_PUB_1A=$(get_id "aws ec2 describe-subnets --filters Name=tag:Name,Values=VPC-A-Public-Subnet-1a Name=vpc-id,Values=$VPC_A" "Subnets[0].SubnetId")
SUB_A_PUB_1B=$(get_id "aws ec2 describe-subnets --filters Name=tag:Name,Values=VPC-A-Public-Subnet-1b Name=vpc-id,Values=$VPC_A" "Subnets[0].SubnetId")
SG_WEB=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=SG-WebPortal Name=vpc-id,Values=$VPC_A" "SecurityGroups[0].GroupId")
ALB_DNS=$(get_id "aws elbv2 describe-load-balancers --names $PROJECT-External-ALB" "LoadBalancers[0].DNSName")
[ -z "$ALB_DNS" ] && die "Day 1 ALB not found — run the Day 1 script first."

read -r INV_ID INV_AZ INV_IP < <(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=$PROJECT-Inventory Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[0].Instances[0].[InstanceId,Placement.AvailabilityZone,PrivateIpAddress]' --output text)
[ -z "${INV_ID:-}" ] || [ "$INV_ID" = "None" ] && die "Day 1 Inventory instance not found."
WEB_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-WebPortal Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PrivateIpAddress")
BASTION_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Bastion Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PublicIpAddress")
ok "VPC A=$VPC_A  ALB=$ALB_DNS  Inventory=$INV_ID ($INV_AZ / $INV_IP)  WebPortal=$WEB_IP"

# ─────────────────────────────────────────────────────────────────────────────
# 2. S3 static-assets bucket (block all public access)
# ─────────────────────────────────────────────────────────────────────────────
log "S3 static-assets bucket"
BUCKET="swiftcart-static-assets-${ACCOUNT_ID}"
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  if [ "$REGION" = "us-east-1" ]; then
    confirm_run aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    confirm_run aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi
confirm_run aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
confirm_run aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT}]" >/dev/null 2>&1 || true
record BUCKET "$BUCKET"
ok "Bucket s3://$BUCKET (all public access blocked)"

# Upload a starter index.html so CloudFront has something to serve.
# (Local /tmp file prep is NOT gated; the upload IS.)
cat > /tmp/index.html <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>SwiftCart</title></head>
<body style="font-family:system-ui;max-width:640px;margin:4rem auto">
<h1>SwiftCart Edge Content</h1>
<p>Served from S3 via CloudFront. Dynamic paths (/api/*, /checkout, /product/*) pass through to the ALB.</p>
</body></html>
HTML
confirm_run aws s3 cp /tmp/index.html "s3://$BUCKET/index.html" --content-type text/html >/dev/null
ok "Uploaded index.html"

# ─────────────────────────────────────────────────────────────────────────────
# 3. CloudFront: Origin Access Control + distribution + S3 bucket policy
# ─────────────────────────────────────────────────────────────────────────────
log "CloudFront"
OAC_ID=$(get_id "aws cloudfront list-origin-access-controls" "OriginAccessControlList.Items[?Name=='$PROJECT-OAC'].Id | [0]")
if [ -z "$OAC_ID" ]; then
  OAC_ID=$(confirm_run aws cloudfront create-origin-access-control \
    --origin-access-control-config "Name=$PROJECT-OAC,Description=SwiftCart S3 OAC,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)
fi
record OAC_ID "$OAC_ID"
ok "OAC=$OAC_ID"

# Reuse an existing distribution (matched by Comment) or create one
read -r CF_ID CF_ARN CF_DOMAIN < <(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='$PROJECT-CDN'].[Id,ARN,DomainName] | [0]" --output text 2>/dev/null || echo "")
if [ -z "${CF_ID:-}" ] || [ "$CF_ID" = "None" ]; then
  S3_DOMAIN="${BUCKET}.s3.${REGION}.amazonaws.com"
  # Shared property block for the ALB behaviors (merged INTO each item object —
  # no leading '{'; each item supplies its own braces around PathPattern + this).
  ALB_BEHAVIOR='"TargetOriginId":"'"$PROJECT"'-ALB-Origin",
        "ViewerProtocolPolicy":"redirect-to-https",
        "CachePolicyId":"'"$CACHE_DISABLED"'",
        "OriginRequestPolicyId":"'"$ORP_ALLVIEWER"'",
        "Compress":false,
        "AllowedMethods":{"Quantity":7,"Items":["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
          "CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}}'
  cat > /tmp/swiftcart-cf.json <<JSON
{
  "CallerReference": "swiftcart-cdn-$(date +%s)",
  "Comment": "$PROJECT-CDN",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Aliases": { "Quantity": 0 },
  "Origins": {
    "Quantity": 2,
    "Items": [
      {
        "Id": "s3-static",
        "DomainName": "$S3_DOMAIN",
        "OriginAccessControlId": "$OAC_ID",
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      },
      {
        "Id": "$PROJECT-ALB-Origin",
        "DomainName": "$ALB_DNS",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] },
          "OriginReadTimeout": 30,
          "OriginKeepaliveTimeout": 5
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-static",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "$CACHE_OPTIMIZED",
    "Compress": true,
    "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } }
  },
  "CacheBehaviors": {
    "Quantity": 4,
    "Items": [
      { "PathPattern": "/api/*",     $ALB_BEHAVIOR },
      { "PathPattern": "/checkout",  $ALB_BEHAVIOR },
      { "PathPattern": "/product/*", $ALB_BEHAVIOR },
      { "PathPattern": "/health",    $ALB_BEHAVIOR }
    ]
  },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true }
}
JSON
  read -r CF_ID CF_ARN CF_DOMAIN < <(confirm_run aws cloudfront create-distribution \
    --distribution-config file:///tmp/swiftcart-cf.json \
    --query 'Distribution.[Id,ARN,DomainName]' --output text)
fi
record CF_ID "$CF_ID"; record CF_ARN "$CF_ARN"; record CF_DOMAIN "$CF_DOMAIN"
ok "Distribution $CF_ID -> $CF_DOMAIN"

# S3 bucket policy: only this distribution may read the bucket (OAC)
cat > /tmp/swiftcart-bucket-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipalReadOnly",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "$CF_ARN" } }
  }]
}
JSON
confirm_run aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/swiftcart-bucket-policy.json
ok "Bucket policy bound to the distribution"

# ─────────────────────────────────────────────────────────────────────────────
# 4. EFS shared file system + mount SG + mount targets (VPC A)
# ─────────────────────────────────────────────────────────────────────────────
log "EFS (shared uploads for the web tier)"
SG_EFS=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=SG-EFS-Mount Name=vpc-id,Values=$VPC_A" "SecurityGroups[0].GroupId")
if [ -z "$SG_EFS" ]; then
  SG_EFS=$(confirm_run aws ec2 create-security-group --group-name SG-EFS-Mount \
    --description "NFS 2049 from the web portal" --vpc-id "$VPC_A" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=SG-EFS-Mount},{Key=Project,Value=$PROJECT}]" \
    --query 'GroupId' --output text)
fi
# Allow NFS only from the Web Portal SG
ensure_ingress --group-id "$SG_EFS" \
  --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=$SG_WEB}]"
record SG_EFS "$SG_EFS"

EFS_ID=$(get_id "aws efs describe-file-systems" "FileSystems[?CreationToken=='$PROJECT-Shared-Uploads'].FileSystemId | [0]")
if [ -z "$EFS_ID" ]; then
  EFS_ID=$(confirm_run aws efs create-file-system --creation-token "$PROJECT-Shared-Uploads" \
    --encrypted --tags "Key=Name,Value=$PROJECT-Shared-Uploads" "Key=Project,Value=$PROJECT" \
    --query 'FileSystemId' --output text)
fi
record EFS_ID "$EFS_ID"
wait_state "aws efs describe-file-systems --file-system-id $EFS_ID" "FileSystems[0].LifeCycleState" "available"

# One mount target per public subnet, if not already present
EXISTING_MT_SUBNETS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].SubnetId' --output text 2>/dev/null || echo "")
for sub in "$SUB_A_PUB_1A" "$SUB_A_PUB_1B"; do
  case " $EXISTING_MT_SUBNETS " in
    *" $sub "*) : ;;  # already has a mount target
    *) confirm_run aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$sub" \
         --security-groups "$SG_EFS" >/dev/null ;;
  esac
done
# Wait for all mount targets to be available (READ-ONLY wait)
for mt in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'MountTargets[].MountTargetId' --output text); do
  wait_state "aws efs describe-mount-targets --mount-target-id $mt" "MountTargets[0].LifeCycleState" "available"
done
ok "EFS=$EFS_ID (mount targets available in both AZs)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. EBS gp3 volume + attach to the Inventory instance (VPC B)
# ─────────────────────────────────────────────────────────────────────────────
log "EBS (high-IOPS cache for the inventory tier)"
EBS_ID=$(get_id "aws ec2 describe-volumes --filters Name=tag:Name,Values=Inventory-Cache-DB Name=status,Values=available,in-use,creating" "Volumes[0].VolumeId")
if [ -z "$EBS_ID" ]; then
  EBS_ID=$(confirm_run aws ec2 create-volume --volume-type gp3 --size "$EBS_SIZE_GIB" \
    --iops "$EBS_IOPS" --throughput "$EBS_THROUGHPUT" --availability-zone "$INV_AZ" \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=Inventory-Cache-DB},{Key=Project,Value=$PROJECT}]" \
    --query 'VolumeId' --output text)
fi
record EBS_ID "$EBS_ID"
aws ec2 wait volume-available --volume-ids "$EBS_ID" 2>/dev/null || true
# Attach only if not already attached to the inventory instance
ATTACHED_TO=$(aws ec2 describe-volumes --volume-ids "$EBS_ID" \
  --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || echo "")
if [ "$ATTACHED_TO" != "$INV_ID" ]; then
  confirm_run aws ec2 attach-volume --volume-id "$EBS_ID" --instance-id "$INV_ID" --device /dev/sdf >/dev/null
  aws ec2 wait volume-in-use --volume-ids "$EBS_ID"
fi
ok "EBS=$EBS_ID attached to $INV_ID at /dev/sdf"

# ─────────────────────────────────────────────────────────────────────────────
# 6. OS-level: mount EFS on the Web Portal, format+mount EBS on the Inventory box
#    Driven over the bastion via SSH (ProxyCommand form, absolute key path).
#    Each remote step is printed and consented; declining skips it. Best-effort —
#    prints manual steps on failure.
# ─────────────────────────────────────────────────────────────────────────────
EFS_MOUNT="/var/www/swiftcart/shared_uploads"
EBS_MOUNT="/mnt/inventory_cache"

print_manual_mounts() {
  cat <<MANUAL

  Run these manually if the automated mount step was skipped/failed.
  (ProxyCommand form — explicit identity on BOTH hops, absolute key path.)

  # Web Portal (via bastion):
  ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$WEB_IP
    sudo yum install -y amazon-efs-utils
    sudo mkdir -p $EFS_MOUNT
    sudo mount -t efs -o tls $EFS_ID:/ $EFS_MOUNT
    echo "$EFS_ID:/ $EFS_MOUNT efs _netdev,tls 0 0" | sudo tee -a /etc/fstab

  # Inventory (via bastion):
  ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$INV_IP
    sudo mkfs -t xfs /dev/xvdf              # only if unformatted
    sudo mkdir -p $EBS_MOUNT
    sudo mount /dev/xvdf $EBS_MOUNT
    UUID=\$(sudo blkid -s UUID -o value /dev/xvdf)
    echo "UUID=\$UUID $EBS_MOUNT xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
MANUAL
}

# ssh_exec <target-private-ip> ; remote bash script arrives on stdin.
# MUTATING (changes the remote host) — the exact remote script is printed and
# consented before it runs. Returns 2 if the user declines (caller then skips).
ssh_exec() {
  local target="$1" script
  script=$(cat)   # capture the remote script from the heredoc so we can show it
  _msg_tty $'\n'"${C_CMD}\$ ssh -o ProxyCommand=\"ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP\" -i $KEY_FILE ec2-user@$target bash -s <<'REMOTE'${C_OFF}"$'\n'
  _msg_tty "$script"$'\n'
  _msg_tty "${C_CMD}REMOTE${C_OFF}"$'\n'
  if ! _consent; then _msg_tty "    (skipped by user)"$'\n'; return 2; fi
  printf '%s\n' "$script" | ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
      -o "ProxyCommand=ssh -i $KEY_FILE -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -W %h:%p ec2-user@$BASTION_IP" \
      "ec2-user@$target" "bash -s"
}

do_os_mounts() {
  [ -f "$KEY_FILE" ] || { warn "Key $KEY_FILE not found — skipping OS mounts"; return 1; }
  [ -n "$BASTION_IP" ] && [ "$BASTION_IP" != "None" ] || { warn "No bastion public IP — skipping OS mounts"; return 1; }
  chmod 400 "$KEY_FILE" 2>/dev/null || true

  # Make sure THIS host can reach the bastion over SSH (MUTATING — gated)
  MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]' || echo "")
  SG_BASTION=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=SG-BastionHost Name=vpc-id,Values=$VPC_A" "SecurityGroups[0].GroupId")
  if [ -n "$MY_IP" ] && [ -n "$SG_BASTION" ]; then
    ensure_ingress --group-id "$SG_BASTION" --protocol tcp --port 22 --cidr "${MY_IP}/32" || true
  fi

  log "Mounting EFS on the Web Portal ($WEB_IP)…"
  ssh_exec "$WEB_IP" <<REMOTE || return 1
set -e
sudo yum install -y amazon-efs-utils >/dev/null
sudo mkdir -p $EFS_MOUNT
grep -qs "$EFS_ID:/ $EFS_MOUNT " /etc/fstab || echo "$EFS_ID:/ $EFS_MOUNT efs _netdev,tls 0 0" | sudo tee -a /etc/fstab >/dev/null
mountpoint -q $EFS_MOUNT || sudo mount -t efs -o tls $EFS_ID:/ $EFS_MOUNT
df -hT | grep -i efs || true
REMOTE
  ok "EFS mounted at $EFS_MOUNT on the Web Portal"

  log "Formatting + mounting EBS on the Inventory box ($INV_IP)…"
  ssh_exec "$INV_IP" <<'REMOTE' || return 1
set -e
DEV=""
for i in $(seq 1 30); do
  for c in /dev/xvdf /dev/nvme1n1 /dev/sdf; do [ -b "$c" ] && DEV="$c" && break; done
  [ -n "$DEV" ] && break; sleep 2
done
[ -n "$DEV" ] || { echo "EBS device not found"; lsblk; exit 1; }
if ! sudo blkid "$DEV" >/dev/null 2>&1; then sudo mkfs -t xfs "$DEV"; fi
sudo mkdir -p /mnt/inventory_cache
UUID=$(sudo blkid -s UUID -o value "$DEV")
grep -qs "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/inventory_cache xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
mountpoint -q /mnt/inventory_cache || sudo mount /mnt/inventory_cache
df -h /mnt/inventory_cache
REMOTE
  ok "EBS formatted (XFS) and mounted at $EBS_MOUNT on the Inventory box"
  return 0
}

if [ "$DO_OS_MOUNTS" = "true" ]; then
  log "OS-level storage mounts (over bastion)"
  if do_os_mounts; then ok "Storage mounted on both instances"; else warn "OS mounts incomplete — see manual steps below"; print_manual_mounts; fi
else
  warn "DO_OS_MOUNTS=false — skipping automated mounts"; print_manual_mounts
fi

# ─────────────────────────────────────────────────────────────────────────────
# Optional: wait for the CDN to finish deploying (READ-ONLY wait)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$WAIT_CLOUDFRONT" = "true" ]; then
  log "Waiting for CloudFront to deploy (~10-15 min)…"
  aws cloudfront wait distribution-deployed --id "$CF_ID"
  ok "Distribution deployed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
cat <<SUMMARY

════════════════════════════════════════════════════════════════════
  SwiftCart Day 2 — provisioning complete
════════════════════════════════════════════════════════════════════
  CloudFront   : https://$CF_DOMAIN   (id $CF_ID)
  S3 bucket    : s3://$BUCKET   (private, OAC-only)
  EFS          : $EFS_ID  -> $EFS_MOUNT (web portal)
  EBS (gp3)    : $EBS_ID  -> $EBS_MOUNT (inventory, ${EBS_SIZE_GIB}GiB/${EBS_IOPS} IOPS)

  CloudFront takes ~10-15 min to deploy. Once "Deployed", validate:
    # Static edge (S3 origin):
    curl https://$CF_DOMAIN/index.html
    # Dynamic pass-through (ALB origin -> Web Portal -> TGW -> Inventory):
    curl https://$CF_DOMAIN/product/SKU-1001
    curl -X POST https://$CF_DOMAIN/checkout \\
      -H 'Content-Type: application/json' \\
      -d '{"sku":"SKU-1001","quantity":2,"email":"test@example.com"}'

SUMMARY

# SSH help — concrete only if the key is on this host (see Day 1). ProxyCommand
# form because some OpenSSH builds don't pass -i to a '-J' jump host.
if [ -f "$KEY_FILE" ]; then
  cat <<SSHHELP
  SSH into an instance via the bastion (ProxyCommand form — a plain 'ssh -J' can
  fail because some OpenSSH builds don't hand -i to the jump connection):
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$WEB_IP
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$INV_IP
SSHHELP
else
  cat <<SSHHELP
  SSH: ${KEY_NAME}.pem is NOT on this host ($KEY_FILE). Bring it here first
  (scp it from wherever it lives + chmod 400), then use the ProxyCommand form:
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@<private-ip>
SSHHELP
fi

cat <<SUMMARY

  Storage checks:
    # EFS (on Web Portal): echo hi | sudo tee $EFS_MOUNT/test.txt
    # EBS (on Inventory):  sudo dd if=/dev/zero of=$EBS_MOUNT/testfile bs=1M count=1024

  State saved to: $STATE_FILE
  Tear down Day 2 with: ./swiftcart-day2-teardown.sh   (leaves Day 1 intact)
════════════════════════════════════════════════════════════════════
SUMMARY
