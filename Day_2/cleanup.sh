#!/usr/bin/env bash
###############################################################################
# SwiftCart — Day 2 Teardown
# Tears down everything created by swiftcart-day2-provision.sh, WITHOUT
# touching the Day 1 stack (VPCs, ALB, EC2, TGW stay intact).
#
# Order: unmount OS-level storage (best-effort, over bastion) -> detach+delete
# EBS volume -> delete EFS mount targets -> delete EFS -> delete SG-EFS-Mount ->
# disable+delete CloudFront distribution -> delete OAC -> empty+delete S3 bucket.
#
# USAGE
#   chmod +x swiftcart-day2-teardown.sh
#   ./swiftcart-day2-teardown.sh            # interactive: confirm each deletion
#   ./swiftcart-day2-teardown.sh -y         # non-interactive: auto-approve all
#
# CloudFront distributions must be disabled before they can be deleted, and
# AWS needs the change to fully propagate first — this can take ~10-15 min.
# Set WAIT_CLOUDFRONT=false to skip waiting and just leave it disabled (you'll
# need to re-run this script later to finish deleting it).
###############################################################################

set -uo pipefail   # no -e — keep going even if one step fails

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
PROJECT="SwiftCart"
KEY_NAME="${KEY_NAME:-swiftcart-key}"
STATE_FILE="./swiftcart-day2-state.env"
WAIT_CLOUDFRONT="${WAIT_CLOUDFRONT:-true}"
SKIP_OS_UNMOUNT="${SKIP_OS_UNMOUNT:-false}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-wait-cloudfront) WAIT_CLOUDFRONT="false" ;;
    --skip-os-unmount)    SKIP_OS_UNMOUNT="true" ;;
    -h|--help)
      cat <<USAGE
Usage: ${0##*/} [--no-wait-cloudfront] [--skip-os-unmount] [-h|--help]
  --no-wait-cloudfront    Disable the distribution but don't block waiting to delete it.
  --skip-os-unmount       Skip the SSH-driven unmount step (just detach/delete storage).

Runs fully non-interactively — no confirmation prompts, deletes immediately.
USAGE
      exit 0 ;;
    *) printf '\033[1;31m[FATAL] Unknown option: %s\033[0m\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }

if [ -f "$STATE_FILE" ]; then
  log "Loading $STATE_FILE"
  set -a; source "$STATE_FILE"; set +a
else
  warn "$STATE_FILE not found — falling back to tag/name-based lookup for everything"
fi

KEY_FILE="${KEY_FILE:-$PWD/${KEY_NAME}.pem}"

_msg_tty() { if [[ -w /dev/tty ]]; then printf '%s' "$1" >/dev/tty; else printf '%s' "$1" >&2; fi; }

# Runs the command directly — no confirmation prompt. Still echoes what's
# running so you have a log, and keeps going even if one step fails.
confirm_run() {
  _msg_tty $'\n'"\033[1;35m\$ $*\033[0m"$'\n'
  "$@" || warn "Command failed (continuing): $*"
}

get_id() {
  local out; out=$(eval "$1 --query '$2' --output text" 2>/dev/null) || out=""
  [ "$out" = "None" ] && out=""
  printf '%s' "$out"
}

# ── Discover anything missing from state (fallback lookups) ────────────────
: "${VPC_A:=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-VPC-A-Public" "Vpcs[0].VpcId")}"
: "${BUCKET:=swiftcart-static-assets-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"
: "${OAC_ID:=$(get_id "aws cloudfront list-origin-access-controls" "OriginAccessControlList.Items[?Name=='$PROJECT-OAC'].Id | [0]")}"
if [ -z "${CF_ID:-}" ]; then
  read -r CF_ID CF_DOMAIN < <(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='$PROJECT-CDN'].[Id,DomainName] | [0]" --output text 2>/dev/null || echo "")
  [ "$CF_ID" = "None" ] && CF_ID=""
fi
: "${EFS_ID:=$(get_id "aws efs describe-file-systems" "FileSystems[?CreationToken=='$PROJECT-Shared-Uploads'].FileSystemId | [0]")}"
: "${SG_EFS:=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=SG-EFS-Mount Name=vpc-id,Values=$VPC_A" "SecurityGroups[0].GroupId")}"
: "${EBS_ID:=$(get_id "aws ec2 describe-volumes --filters Name=tag:Name,Values=Inventory-Cache-DB Name=status,Values=available,in-use,creating" "Volumes[0].VolumeId")}"

INV_ID=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Inventory Name=instance-state-name,Values=pending,running,stopping,stopped" "Reservations[0].Instances[0].InstanceId")
INV_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Inventory Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PrivateIpAddress")
WEB_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-WebPortal Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PrivateIpAddress")
BASTION_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Bastion Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PublicIpAddress")

echo "════════════════════════════════════════════════════════════════════"
echo "  SwiftCart Day 2 — Teardown (Day 1 stack left intact)"
echo "  Region: $REGION"
echo "════════════════════════════════════════════════════════════════════"

# ── 1. OS-level unmount (best-effort, over bastion) ─────────────────────────
EFS_MOUNT="/var/www/swiftcart/shared_uploads"
EBS_MOUNT="/mnt/inventory_cache"

ssh_exec() {
  local target="$1" script
  script=$(cat)
  _msg_tty $'\n'"\033[1;35m\$ ssh ... ec2-user@$target bash -s <<'REMOTE'\033[0m"$'\n'
  _msg_tty "$script"$'\n'"\033[1;35mREMOTE\033[0m"$'\n'
  printf '%s\n' "$script" | ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
      -o "ProxyCommand=ssh -i $KEY_FILE -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -W %h:%p ec2-user@$BASTION_IP" \
      "ec2-user@$target" "bash -s"
}

if [ "$SKIP_OS_UNMOUNT" != "true" ]; then
  log "OS-level unmounts (over bastion, best-effort)"
  if [ -f "$KEY_FILE" ] && [ -n "$BASTION_IP" ] && [ "$BASTION_IP" != "None" ]; then
    chmod 400 "$KEY_FILE" 2>/dev/null || true
    if [ -n "$WEB_IP" ] && [ "$WEB_IP" != "None" ]; then
      ssh_exec "$WEB_IP" <<REMOTE
sudo umount $EFS_MOUNT 2>/dev/null || true
sudo sed -i.bak "\\|$EFS_MOUNT|d" /etc/fstab 2>/dev/null || true
echo "unmounted $EFS_MOUNT (if it was mounted)"
REMOTE
    fi
    if [ -n "$INV_IP" ] && [ "$INV_IP" != "None" ]; then
      ssh_exec "$INV_IP" <<REMOTE
sudo umount $EBS_MOUNT 2>/dev/null || true
sudo sed -i.bak "\\|$EBS_MOUNT|d" /etc/fstab 2>/dev/null || true
echo "unmounted $EBS_MOUNT (if it was mounted)"
REMOTE
    fi
  else
    warn "No key/bastion available — skipping OS unmounts (AWS-side deletion below still proceeds)"
  fi
else
  warn "--skip-os-unmount set — going straight to AWS-side deletion"
fi

# ── 2. EBS volume: detach then delete ───────────────────────────────────────
log "EBS volume"
if [ -n "${EBS_ID:-}" ]; then
  STATE=$(aws ec2 describe-volumes --volume-ids "$EBS_ID" --query 'Volumes[0].State' --output text 2>/dev/null || echo "")
  if [ "$STATE" = "in-use" ]; then
    confirm_run aws ec2 detach-volume --volume-id "$EBS_ID"
    aws ec2 wait volume-available --volume-ids "$EBS_ID" 2>/dev/null || true
  fi
  confirm_run aws ec2 delete-volume --volume-id "$EBS_ID"
else
  warn "No EBS volume found, skipping"
fi

# ── 3. EFS: delete mount targets, then the file system ──────────────────────
log "EFS"
if [ -n "${EFS_ID:-}" ]; then
  MTS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'MountTargets[].MountTargetId' --output text 2>/dev/null)
  for mt in $MTS; do
    [ -n "$mt" ] && [ "$mt" != "None" ] && confirm_run aws efs delete-mount-target --mount-target-id "$mt"
  done
  if [ -n "$MTS" ]; then
    log "Waiting for mount targets to delete…"
    while true; do
      remaining=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)
      [ "$remaining" = "0" ] && break
      sleep 5
    done
  fi
  confirm_run aws efs delete-file-system --file-system-id "$EFS_ID"
else
  warn "No EFS file system found, skipping"
fi

# ── 4. SG-EFS-Mount ──────────────────────────────────────────────────────────
log "Security group"
if [ -n "${SG_EFS:-}" ]; then
  # SG deletion can race just after mount targets/ENIs disappear — retry briefly.
  for i in 1 2 3 4 5; do
    out=$(aws ec2 delete-security-group --group-id "$SG_EFS" 2>&1) && { ok "Deleted $SG_EFS"; break; }
    case "$out" in *DependencyViolation*) sleep 10 ;; *) warn "$out"; break ;; esac
  done
else
  warn "No SG-EFS-Mount found, skipping"
fi

# ── 5. CloudFront: disable, wait, delete ────────────────────────────────────
log "CloudFront distribution"
if [ -n "${CF_ID:-}" ]; then
  ETAG=$(aws cloudfront get-distribution --id "$CF_ID" --query 'ETag' --output text 2>/dev/null)
  ENABLED=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'DistributionConfig.Enabled' --output text 2>/dev/null)
  if [ "$ENABLED" = "True" ]; then
    aws cloudfront get-distribution-config --id "$CF_ID" --query 'DistributionConfig' --output json > /tmp/cf-config.json
    jq '.Enabled = false' /tmp/cf-config.json > /tmp/cf-config-disabled.json
    confirm_run aws cloudfront update-distribution --id "$CF_ID" \
      --distribution-config file:///tmp/cf-config-disabled.json --if-match "$ETAG" >/dev/null
  else
    warn "Distribution already disabled"
  fi

  if [ "$WAIT_CLOUDFRONT" = "true" ]; then
    log "Waiting for distribution to finish deploying disabled state (~10-15 min)…"
    aws cloudfront wait distribution-deployed --id "$CF_ID" 2>/dev/null || true
    ETAG=$(aws cloudfront get-distribution --id "$CF_ID" --query 'ETag' --output text 2>/dev/null)
    confirm_run aws cloudfront delete-distribution --id "$CF_ID" --if-match "$ETAG"
  else
    warn "WAIT_CLOUDFRONT=false — distribution left disabled, NOT deleted."
    warn "Re-run this script later (once it shows 'Deployed' + disabled in the console) to delete it."
  fi
else
  warn "No CloudFront distribution found, skipping"
fi

# ── 6. Origin Access Control ─────────────────────────────────────────────────
if [ -n "${OAC_ID:-}" ] && { [ "$WAIT_CLOUDFRONT" = "true" ] || [ -z "${CF_ID:-}" ]; }; then
  log "Origin Access Control"
  OAC_ETAG=$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query 'ETag' --output text 2>/dev/null)
  if [ -n "$OAC_ETAG" ] && [ "$OAC_ETAG" != "None" ]; then
    confirm_run aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$OAC_ETAG"
  fi
fi

# ── 7. S3 bucket: remove policy, empty, delete ──────────────────────────────
log "S3 bucket"
if [ -n "${BUCKET:-}" ] && aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  confirm_run aws s3api delete-bucket-policy --bucket "$BUCKET"
  confirm_run aws s3 rm "s3://$BUCKET" --recursive
  confirm_run aws s3api delete-bucket --bucket "$BUCKET"
else
  warn "Bucket not found (or already deleted), skipping"
fi

# ── Cleanup state file ───────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  confirm_run rm -f "$STATE_FILE"
fi

echo "════════════════════════════════════════════════════════════════════"
ok "Day 2 teardown pass complete. Day 1 stack (VPCs/ALB/EC2/TGW) untouched."
warn "If CloudFront was left disabled (--no-wait-cloudfront), re-run this script"
warn "once it shows Deployed+Disabled to finish deleting it — it still bills until then."
warn "Double-check the AWS Console (CloudFront/S3/EFS/EC2 volumes) for stragglers."
echo "════════════════════════════════════════════════════════════════════"
