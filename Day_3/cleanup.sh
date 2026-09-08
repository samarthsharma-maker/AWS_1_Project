#!/usr/bin/env bash
###############################################################################
# SwiftCart — Day 3 Teardown
# Tears down everything created by swiftcart-day3-provision.sh, WITHOUT
# touching Day 1 (VPC/ALB/EC2/TGW) or Day 2 (CloudFront/S3/EFS/EBS).
#
# Order: revert Web Portal from Docker back to the Day 1 systemd service
# (best-effort, over bastion) -> delete CloudWatch alarm -> delete SRE SNS
# topic (+ subscriptions) -> stop + delete CloudTrail trail -> empty + delete
# its S3 bucket -> delete the SQS->Lambda event source mapping -> delete the
# Lambda function -> delete the Lambda IAM role.
#
# Runs fully non-interactively — no confirmation prompts, deletes immediately.
# Every command is still echoed to the terminal as a log, and keeps going even
# if one step fails.
#
# USAGE
#   chmod +x swiftcart-day3-teardown.sh
#   ./swiftcart-day3-teardown.sh
#
# FLAGS
#   --skip-docker-revert   Skip the SSH-driven revert-to-systemd step.
###############################################################################

set -uo pipefail   # no -e — keep going even if one step fails

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
PROJECT="SwiftCart"
KEY_NAME="${KEY_NAME:-swiftcart-key}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kubeboiii/swiftcart-aws/main}"
STATE_FILE="./swiftcart-day3-state.env"
SKIP_DOCKER_REVERT="${SKIP_DOCKER_REVERT:-false}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-docker-revert) SKIP_DOCKER_REVERT="true" ;;
    -h|--help)
      cat <<USAGE
Usage: ${0##*/} [--skip-docker-revert] [-h|--help]
  --skip-docker-revert   Skip the SSH-driven revert-to-systemd step.

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

# Runs the command directly — no confirmation prompt. Still echoes it for a log.
confirm_run() {
  _msg_tty $'\n'"\033[1;35m\$ $*\033[0m"$'\n'
  "$@" || warn "Command failed (continuing): $*"
}

get_id() {
  local out; out=$(eval "$1 --query '$2' --output text" 2>/dev/null) || out=""
  [ "$out" = "None" ] && out=""
  printf '%s' "$out"
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

# ── Discover anything missing from state (fallback lookups) ────────────────
: "${LAMBDA_ROLE:=$PROJECT-ServerlessProcessor-Role}"
: "${LAMBDA_NAME:=$PROJECT-Order-Processor}"
: "${TRAIL_NAME:=$PROJECT-Management-Audit}"
: "${CT_BUCKET:=swiftcart-cloudtrail-${ACCOUNT_ID}-${REGION}}"
: "${SRE_TOPIC_ARN:=arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT}-SRE-Alerts}"
if [ -z "${ESM_UUID:-}" ]; then
  QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$(aws sqs get-queue-url --queue-name OrderProcessingQueue --query QueueUrl --output text 2>/dev/null)" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text 2>/dev/null || echo "")
  if [ -n "$QUEUE_ARN" ]; then
    ESM_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" \
      --query "EventSourceMappings[?EventSourceArn=='$QUEUE_ARN'].UUID | [0]" --output text 2>/dev/null || echo "")
    [ "$ESM_UUID" = "None" ] && ESM_UUID=""
  fi
fi

VPC_A=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-VPC-A-Public" "Vpcs[0].VpcId")
read -r WEB_ID WEB_IP < <(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=$PROJECT-WebPortal Name=instance-state-name,Values=running,pending,stopping,stopped \
  --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]' --output text 2>/dev/null || echo "")
BASTION_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Bastion Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PublicIpAddress")

echo "════════════════════════════════════════════════════════════════════"
echo "  SwiftCart Day 3 — Teardown (Day 1 & Day 2 stacks left intact)"
echo "  Region: $REGION"
echo "════════════════════════════════════════════════════════════════════"

# ── 1. Revert Web Portal: stop the Docker container, re-enable systemd unit ──
if [ "$SKIP_DOCKER_REVERT" != "true" ]; then
  log "Reverting Web Portal from Docker to the Day 1 systemd service (over bastion, best-effort)"
  if [ -f "$KEY_FILE" ] && [ -n "$WEB_ID" ] && [ "$WEB_ID" != "None" ] && [ -n "$BASTION_IP" ] && [ "$BASTION_IP" != "None" ]; then
    chmod 400 "$KEY_FILE" 2>/dev/null || true
    remote_script=$(cat <<'REMOTE'
set -e
sudo docker rm -f swiftcart_web_container 2>/dev/null || true
if command -v docker-compose >/dev/null 2>&1 || [ -x /usr/local/bin/docker-compose ]; then
  cd ~/swiftcart_docker 2>/dev/null && sudo /usr/local/bin/docker-compose down 2>/dev/null || true
fi
sudo systemctl enable --now swiftcart-web 2>/dev/null || echo "swiftcart-web unit not present/could not start — check manually"
sleep 2
curl -fsS http://localhost/health || echo "(health check not responding yet)"
REMOTE
)
    _msg_tty $'\n'"\033[1;35m\$ ssh ... ec2-user@$WEB_IP bash -s <<'REMOTE'\033[0m"$'\n'
    _msg_tty "$remote_script"$'\n'"\033[1;35mREMOTE\033[0m"$'\n'
    printf '%s\n' "$remote_script" | ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
      -o "ProxyCommand=ssh -i $KEY_FILE -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -W %h:%p ec2-user@$BASTION_IP" \
      "ec2-user@$WEB_IP" "bash -s" || warn "Docker revert failed/incomplete — check the Web Portal manually"
    ok "Web Portal reverted to the systemd service (best-effort)"
  else
    warn "No key/bastion/instance available — skipping Docker revert. Container may keep running until the instance is stopped/terminated."
  fi
  # Reset IMDS hop limit back to the Day 1 default (1) now that no container needs it
  if [ -n "$WEB_ID" ] && [ "$WEB_ID" != "None" ]; then
    confirm_run aws ec2 modify-instance-metadata-options --instance-id "$WEB_ID" \
      --http-put-response-hop-limit 1 --http-endpoint enabled >/dev/null
  fi
else
  warn "--skip-docker-revert set — Docker container left running on the Web Portal"
fi

# ── 2. CloudWatch alarm ──────────────────────────────────────────────────────
log "CloudWatch alarm"
confirm_run aws cloudwatch delete-alarms --alarm-names SQS-Queue-Depth-Critical

# ── 3. SRE SNS topic (unsubscribe first, then delete) ───────────────────────
log "SRE SNS topic"
if aws sns get-topic-attributes --topic-arn "$SRE_TOPIC_ARN" >/dev/null 2>&1; then
  SUBS=$(aws sns list-subscriptions-by-topic --topic-arn "$SRE_TOPIC_ARN" --query 'Subscriptions[].SubscriptionArn' --output text 2>/dev/null)
  for s in $SUBS; do
    [ "$s" = "PendingConfirmation" ] && continue
    [ -n "$s" ] && [ "$s" != "None" ] && confirm_run aws sns unsubscribe --subscription-arn "$s"
  done
  confirm_run aws sns delete-topic --topic-arn "$SRE_TOPIC_ARN"
else
  warn "SRE SNS topic not found, skipping"
fi

# ── 4. CloudTrail: stop logging, delete trail, empty + delete its bucket ────
log "CloudTrail"
if aws cloudtrail get-trail --name "$TRAIL_NAME" >/dev/null 2>&1; then
  confirm_run aws cloudtrail stop-logging --name "$TRAIL_NAME"
  confirm_run aws cloudtrail delete-trail --name "$TRAIL_NAME"
else
  warn "CloudTrail trail $TRAIL_NAME not found, skipping"
fi
if aws s3api head-bucket --bucket "$CT_BUCKET" >/dev/null 2>&1; then
  confirm_run aws s3api delete-bucket-policy --bucket "$CT_BUCKET"
  confirm_run aws s3 rm "s3://$CT_BUCKET" --recursive
  confirm_run aws s3api delete-bucket --bucket "$CT_BUCKET"
else
  warn "CloudTrail bucket $CT_BUCKET not found, skipping"
fi

# ── 5. SQS -> Lambda event source mapping ───────────────────────────────────
log "Event source mapping"
if [ -n "${ESM_UUID:-}" ]; then
  confirm_run aws lambda delete-event-source-mapping --uuid "$ESM_UUID"
else
  warn "No event source mapping found, skipping"
fi

# ── 6. Lambda function ───────────────────────────────────────────────────────
log "Lambda function"
if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  confirm_run aws lambda delete-function --function-name "$LAMBDA_NAME"
else
  warn "Lambda $LAMBDA_NAME not found, skipping"
fi

# ── 7. Lambda IAM role ────────────────────────────────────────────────────────
log "IAM role"
if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  POLICIES=$(aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
  for p in $POLICIES; do
    confirm_run aws iam detach-role-policy --role-name "$LAMBDA_ROLE" --policy-arn "$p"
  done
  confirm_run aws iam delete-role --role-name "$LAMBDA_ROLE"
else
  warn "IAM role $LAMBDA_ROLE not found, skipping"
fi

# ── Cleanup state file ───────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  confirm_run rm -f "$STATE_FILE"
fi

echo "════════════════════════════════════════════════════════════════════"
ok "Day 3 teardown pass complete. Day 1 & Day 2 stacks untouched."
warn "If the Docker revert was skipped/failed, SSH in manually and check:"
warn "  sudo docker ps ; sudo systemctl status swiftcart-web"
warn "Double-check the AWS Console (Lambda/CloudTrail/S3/SNS/CloudWatch) for stragglers."
echo "════════════════════════════════════════════════════════════════════"
