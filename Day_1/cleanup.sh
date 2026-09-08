#!/usr/bin/env bash
###############################################################################
# SwiftCart — Day 1 Teardown
# Tears down everything created by swiftcart-day1-provision.sh, in dependency
# order, so it doesn't hit ResourceInUse / DependencyViolation errors.
#
# USAGE
#   chmod +x swiftcart-day1-teardown.sh
#   ./swiftcart-day1-teardown.sh            # interactive: confirm each deletion
#   ./swiftcart-day1-teardown.sh -y         # non-interactive: auto-approve all
#
# Reads IDs from ./swiftcart-state.env when present. If it's missing/partial,
# falls back to tag/name-based lookup (Project=SwiftCart), so this also cleans
# up after a provisioning run that failed partway through.
#
# NOTE: this does NOT delete the local ${KEY_NAME}.pem or deregister/delete the
# AWS key pair by default (so you can re-run provisioning with the same key).
# Pass --delete-key to also remove the AWS-side key pair.
###############################################################################

set -uo pipefail   # NOTE: no -e — teardown must keep going even if one step fails

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
PROJECT="SwiftCart"
STATE_FILE="./swiftcart-state.env"
ASSUME_YES="${ASSUME_YES:-false}"
DELETE_KEY="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)      ASSUME_YES="true" ;;
    --delete-key)  DELETE_KEY="true" ;;
    -h|--help)
      cat <<USAGE
Usage: ${0##*/} [-y|--yes] [--delete-key] [-h|--help]
  -y, --yes       Auto-approve every deletion prompt.
  --delete-key    Also delete the AWS key pair (local .pem file is untouched).
USAGE
      exit 0 ;;
    *) printf '\033[1;31m[FATAL] Unknown option: %s\033[0m\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }

# Load state file if present (id vars become available as shell vars)
if [ -f "$STATE_FILE" ]; then
  log "Loading $STATE_FILE"
  set -a; source "$STATE_FILE"; set +a
else
  warn "$STATE_FILE not found — falling back to tag-based lookup for everything"
fi

_msg_tty() { if [[ -w /dev/tty ]]; then printf '%s' "$1" >/dev/tty; else printf '%s' "$1" >&2; fi; }

confirm_run() {
  _msg_tty $'\n'"\033[1;35m\$ $*\033[0m"$'\n'
  if [ "$ASSUME_YES" != "true" ]; then
    local reply=""
    if [[ -r /dev/tty ]]; then
      _msg_tty "    Delete with the above command? [y/N] "
      read -r reply </dev/tty || true
    fi
    if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
      warn "Skipped."
      return 0
    fi
  fi
  "$@" || warn "Command failed (continuing): $*"
}

get_id() {  # get_id "<describe cmd + filters>" "<jmespath>"
  local out
  out=$(eval "$1 --query '$2' --output text" 2>/dev/null) || out=""
  [ "$out" = "None" ] && out=""
  printf '%s' "$out"
}

# Fallback lookups by tag, used whenever the state var is empty
: "${VPC_A:=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-VPC-A-Public" "Vpcs[0].VpcId")}"
: "${VPC_B:=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-VPC-B-Private" "Vpcs[0].VpcId")}"
: "${TGW:=$(get_id "aws ec2 describe-transit-gateways --filters Name=tag:Name,Values=$PROJECT-TGW Name=state,Values=available,pending,modifying" "TransitGateways[0].TransitGatewayId")}"
: "${IGW:=$(get_id "aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=$PROJECT-IGW" "InternetGateways[0].InternetGatewayId")}"
: "${NAT:=$(get_id "aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=$PROJECT-NAT Name=state,Values=available,pending" "NatGateways[0].NatGatewayId")}"
: "${EIP_ALLOC:=$(get_id "aws ec2 describe-addresses --filters Name=tag:Name,Values=$PROJECT-NAT-EIP" "Addresses[0].AllocationId")}"
: "${ALB_ARN:=$(get_id "aws elbv2 describe-load-balancers --names $PROJECT-External-ALB" "LoadBalancers[0].LoadBalancerArn")}"
: "${TG_ARN:=$(get_id "aws elbv2 describe-target-groups --names TG-WebPortal" "TargetGroups[0].TargetGroupArn")}"
: "${QUEUE_URL:=$(get_id "aws sqs get-queue-url --queue-name OrderProcessingQueue" "QueueUrl")}"
: "${TOPIC_ARN:=$(aws sns list-topics --query "Topics[?ends_with(TopicArn,':${PROJECT}-Order-Fanout')].TopicArn | [0]" --output text 2>/dev/null)}"
[ "$TOPIC_ARN" = "None" ] && TOPIC_ARN=""
: "${KEY_NAME:=swiftcart-key}"

for v in EC2_BASTION EC2_INV EC2_WEB; do
  case "$v" in
    EC2_BASTION) tagname="$PROJECT-Bastion" ;;
    EC2_INV)     tagname="$PROJECT-Inventory" ;;
    EC2_WEB)     tagname="$PROJECT-WebPortal" ;;
  esac
  if [ -z "${!v:-}" ]; then
    id=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$tagname Name=instance-state-name,Values=pending,running,stopping,stopped" "Reservations[0].Instances[0].InstanceId")
    printf -v "$v" '%s' "$id"
  fi
done

echo "════════════════════════════════════════════════════════════════════"
echo "  SwiftCart Day 1 — Teardown"
echo "  Region: $REGION"
echo "════════════════════════════════════════════════════════════════════"

# ── 1. ALB + Target Group + Listeners ───────────────────────────────────────
log "Load balancer"
if [ -n "${ALB_ARN:-}" ]; then
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text 2>/dev/null)
  for l in $LISTENERS; do
    [ -n "$l" ] && [ "$l" != "None" ] && confirm_run aws elbv2 delete-listener --listener-arn "$l"
  done
  confirm_run aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  log "Waiting for ALB deletion…"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
else
  warn "No ALB found, skipping"
fi
if [ -n "${TG_ARN:-}" ]; then
  confirm_run aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
fi

# ── 2. EC2 instances ─────────────────────────────────────────────────────────
log "EC2 instances"
INSTANCE_IDS=""
for v in "${EC2_BASTION:-}" "${EC2_INV:-}" "${EC2_WEB:-}"; do
  [ -n "$v" ] && INSTANCE_IDS="$INSTANCE_IDS $v"
done
INSTANCE_IDS="${INSTANCE_IDS# }"
if [ -n "$INSTANCE_IDS" ]; then
  # shellcheck disable=SC2086
  confirm_run aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
  log "Waiting for instances to terminate…"
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS 2>/dev/null || true
else
  warn "No EC2 instances found, skipping"
fi

# ── 3. IAM instance profiles + roles ────────────────────────────────────────
log "IAM roles / instance profiles"
rm_role() {  # rm_role <role-name>
  local role="$1"
  if aws iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1; then
    confirm_run aws iam remove-role-from-instance-profile --instance-profile-name "$role" --role-name "$role"
    confirm_run aws iam delete-instance-profile --instance-profile-name "$role"
  fi
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    local policies
    policies=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
    for p in $policies; do
      confirm_run aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
    done
    confirm_run aws iam delete-role --role-name "$role"
  fi
}
rm_role "$PROJECT-WebPortal-Role"
rm_role "$PROJECT-Inventory-Role"

# ── 4. SNS subscriptions + topic, SQS queue ─────────────────────────────────
log "SNS / SQS"
if [ -n "${TOPIC_ARN:-}" ]; then
  SUBS=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query 'Subscriptions[].SubscriptionArn' --output text 2>/dev/null)
  for s in $SUBS; do
    [ "$s" = "PendingConfirmation" ] && continue
    [ -n "$s" ] && [ "$s" != "None" ] && confirm_run aws sns unsubscribe --subscription-arn "$s"
  done
  confirm_run aws sns delete-topic --topic-arn "$TOPIC_ARN"
else
  warn "No SNS topic found, skipping"
fi
if [ -n "${QUEUE_URL:-}" ]; then
  confirm_run aws sqs delete-queue --queue-url "$QUEUE_URL"
else
  warn "No SQS queue found, skipping"
fi

# ── 5. VPC Endpoints ─────────────────────────────────────────────────────────
log "VPC Endpoints"
: "${EP_SQS:=$(get_id "aws ec2 describe-vpc-endpoints --filters Name=tag:Name,Values=SQS-Endpoint" "VpcEndpoints[0].VpcEndpointId")}"
: "${EP_SNS:=$(get_id "aws ec2 describe-vpc-endpoints --filters Name=tag:Name,Values=SNS-Endpoint" "VpcEndpoints[0].VpcEndpointId")}"
for e in "${EP_SQS:-}" "${EP_SNS:-}"; do
  [ -n "$e" ] && confirm_run aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$e"
done

# ── 6. Transit Gateway attachments + TGW ────────────────────────────────────
log "Transit Gateway"
: "${ATTACH_A:=$(get_id "aws ec2 describe-transit-gateway-vpc-attachments --filters Name=tag:Name,Values=TGW-Attach-VPC-A Name=state,Values=available,pending,modifying" "TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId")}"
: "${ATTACH_B:=$(get_id "aws ec2 describe-transit-gateway-vpc-attachments --filters Name=tag:Name,Values=TGW-Attach-VPC-B Name=state,Values=available,pending,modifying" "TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId")}"
for a in "${ATTACH_A:-}" "${ATTACH_B:-}"; do
  if [ -n "$a" ]; then
    confirm_run aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id "$a"
  fi
done
if [ -n "${ATTACH_A:-}" ] || [ -n "${ATTACH_B:-}" ]; then
  log "Waiting for TGW attachments to delete…"
  for a in "${ATTACH_A:-}" "${ATTACH_B:-}"; do
    [ -z "$a" ] && continue
    while true; do
      st=$(aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "$a" \
           --query 'TransitGatewayVpcAttachments[0].State' --output text 2>/dev/null || echo "deleted")
      [ "$st" = "deleted" ] || [ "$st" = "None" ] && break
      sleep 10
    done
  done
fi
if [ -n "${TGW:-}" ]; then
  confirm_run aws ec2 delete-transit-gateway --transit-gateway-id "$TGW"
fi

# ── 7. Security groups (non-default) ────────────────────────────────────────
log "Security groups"
for sgname in SG-BastionHost SG-WebPortal SG-InventoryService SG-VPCEndpoints-A SG-VPCEndpoints-B SG-ALB; do
  for vpc in "${VPC_A:-}" "${VPC_B:-}"; do
    [ -z "$vpc" ] && continue
    id=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=$sgname Name=vpc-id,Values=$vpc" "SecurityGroups[0].GroupId")
    [ -n "$id" ] && confirm_run aws ec2 delete-security-group --group-id "$id"
  done
done

# ── 8. NAT Gateway + EIP release ────────────────────────────────────────────
log "NAT Gateway"
if [ -n "${NAT:-}" ]; then
  confirm_run aws ec2 delete-nat-gateway --nat-gateway-id "$NAT"
  log "Waiting for NAT gateway to delete (~1-2 min)…"
  while true; do
    st=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT" --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
    [ "$st" = "deleted" ] && break
    sleep 10
  done
fi
if [ -n "${EIP_ALLOC:-}" ]; then
  confirm_run aws ec2 release-address --allocation-id "$EIP_ALLOC"
fi

# ── 9. Route tables (custom ones only — skip main) ──────────────────────────
log "Route tables"
for rtvar in RT_A_PUB RT_TGW RT_B_PRV; do
  id="${!rtvar:-}"
  if [ -n "$id" ]; then
    ASSOCS=$(aws ec2 describe-route-tables --route-table-ids "$id" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null)
    for a in $ASSOCS; do
      [ -n "$a" ] && [ "$a" != "None" ] && confirm_run aws ec2 disassociate-route-table --association-id "$a"
    done
    confirm_run aws ec2 delete-route-table --route-table-id "$id"
  fi
done

# ── 10. Internet Gateway (detach + delete) ──────────────────────────────────
log "Internet Gateway"
if [ -n "${IGW:-}" ] && [ -n "${VPC_A:-}" ]; then
  confirm_run aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A"
  confirm_run aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
fi

# ── 11. Subnets ──────────────────────────────────────────────────────────────
log "Subnets"
for subvar in SUB_A_PUB_1A SUB_A_PUB_1B SUB_A_TGW_1A SUB_B_PRV_1A; do
  id="${!subvar:-}"
  [ -n "$id" ] && confirm_run aws ec2 delete-subnet --subnet-id "$id"
done

# ── 12. VPCs ─────────────────────────────────────────────────────────────────
log "VPCs"
for v in "${VPC_A:-}" "${VPC_B:-}"; do
  [ -n "$v" ] && confirm_run aws ec2 delete-vpc --vpc-id "$v"
done

# ── 13. Key pair (opt-in only) ───────────────────────────────────────────────
if [ "$DELETE_KEY" = "true" ]; then
  log "Key pair"
  confirm_run aws ec2 delete-key-pair --key-name "$KEY_NAME"
  warn "Local ${KEY_NAME}.pem was NOT deleted — remove it manually if you want."
fi

# ── Cleanup state file ───────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  confirm_run rm -f "$STATE_FILE"
fi

echo "════════════════════════════════════════════════════════════════════"
ok "Teardown pass complete."
warn "Re-run this script if anything above was skipped or failed — it's idempotent."
warn "Double-check the AWS Console (VPC/EC2/ELB/TGW) for any leftover billable resources."
echo "════════════════════════════════════════════════════════════════════"
