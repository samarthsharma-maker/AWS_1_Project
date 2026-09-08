#!/usr/bin/env bash
###############################################################################
# SwiftCart — Day 3: Modernization, Serverless & Deep Observability
# Builds ON TOP of Day 1 (SQS/SNS/EC2/ALB) and Day 2 (CloudFront/S3/EFS/EBS).
#
# What this provisions (every console step from the Day 3 guide):
#   - IAM role SwiftCart-ServerlessProcessor-Role (Lambda + SQS execution)
#   - Lambda SwiftCart-Order-Processor (Python 3.12, arm64) from the repo code
#   - SQS -> Lambda event source mapping (batch 10, partial-batch-failure reporting)
#   - CloudTrail SwiftCart-Management-Audit (+ its own S3 bucket & policy)
#   - CloudWatch alarm SQS-Queue-Depth-Critical (>=100 visible msgs) -> SNS email
#   - Containerises the Web Portal with Docker + docker-compose (cutover from the
#     Day 1 systemd service), driven over the bastion via SSH.
#
# PREREQUISITES
#   - Day 1 + Day 2 stacks present (this discovers them by name/tag; aborts if not).
#   - Same host/creds as before (needs swiftcart-key.pem + bastion reach for the
#     Docker step). Missing CLI tools auto-install. Set NOTIFY_EMAIL for SRE alerts.
#
# USAGE
#   chmod +x swiftcart-day3-provision.sh
#   NOTIFY_EMAIL=you@example.com ./swiftcart-day3-provision.sh    # interactive
#   NOTIFY_EMAIL=you@example.com ./swiftcart-day3-provision.sh -y # auto-approve all
#   ./swiftcart-day3-provision.sh --help                          # flags + env overrides
#
# INTERACTIVE CONSENT (build path)
#   Every RESOURCE-CREATING or MUTATING step — AWS API calls AND the SSH-driven
#   Docker cutover — is printed verbatim and must be confirmed with 'y' / 'Y'
#   before it runs. Read-only describe/list/get/wait calls, local tool installs,
#   the repo/code fetches, the Lambda zip packaging, and local /tmp file prep run
#   without prompting. Prompts go to the controlling terminal (/dev/tty), so they
#   survive command substitution ( VAR=$(...) ) and output capture. Declining a
#   provisioning command aborts the run; declining the Docker cutover just skips
#   it and the manual commands are printed instead.
#   Pass -y / --yes (or set ASSUME_YES=true) to auto-approve every prompt —
#   commands are still printed before they execute.
#
# IDEMPOTENT: everything is looked up before creation and reused. Re-run to converge.
#
# DEVIATIONS FROM THE DOC (read these):
#   1. The event source mapping is created with ReportBatchItemFailures so the
#      Lambda's `batchItemFailures` return value actually works (the console
#      steps omit this, which would silently make partial-batch handling a no-op).
#   2. Lambda timeout is 30s, not the 3s default. A full batch of 10 x time.sleep(0.5)
#      exceeds 3s and would time out — this is exactly the Day 3 "Hypothesis B" fix.
#   3. The container gets AWS credentials from the instance's IAM role via IMDS,
#      so this script sets the Web Portal's metadata hop limit to 2 (containers add
#      a network hop) instead of the doc's ~/.aws bind-mount, which is empty on an
#      instance-profile-only host and yields NoCredentialsError.
#   4. The containerised Web Portal (per the doc/repo) serves ONLY /health and
#      /checkout — it drops /product/<sku>. After cutover, /product returns 404
#      (via the ALB and via the Day 2 CloudFront /product/* behavior). /checkout
#      -> SNS -> SQS -> Lambda is the path this day exercises.
#
# COST: Lambda + CloudTrail (S3 storage) + the CloudWatch alarm are cheap; the
# Day 1/2 NAT/TGW/ALB/CloudFront/EFS/EBS are the real spend. Teardown when done.
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
REGION="${REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-swiftcart-key}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-CHANGE_ME@example.com}"   # SRE alert email (optional but recommended)
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-true}"
DO_DOCKER="${DO_DOCKER:-true}"                          # SSH cutover of the web portal to Docker
ASSUME_YES="${ASSUME_YES:-false}"                      # true = auto-approve every consent prompt
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kubeboiii/swiftcart-aws/main}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.12}"
LAMBDA_ARCH="${LAMBDA_ARCH:-arm64}"
LAMBDA_TIMEOUT="${LAMBDA_TIMEOUT:-30}"
LAMBDA_MEMORY="${LAMBDA_MEMORY:-128}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.24.0}"
PROJECT="SwiftCart"

export AWS_DEFAULT_REGION="$REGION"
STATE_FILE="./swiftcart-day3-state.env"
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

Environment overrides (all optional): REGION, KEY_NAME, NOTIFY_EMAIL,
AUTO_INSTALL_DEPS, DO_DOCKER, REPO_RAW, LAMBDA_RUNTIME, LAMBDA_ARCH,
LAMBDA_TIMEOUT, LAMBDA_MEMORY, COMPOSE_VERSION, ASSUME_YES.
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
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }
record() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }
get_id() { local o; o=$(eval "$1 --query '$2' --output text" 2>/dev/null) || o=""; [ "$o" = "None" ] && o=""; printf '%s' "$o"; }

# ── Interactive consent (build path). Every mutating command is echoed and must
#    be approved with y/Y. Prompts go to /dev/tty so they survive VAR=$(...).
C_CMD=$'\033[1;35m'
C_OFF=$'\033[0m'
_msg_tty() {
  if [[ -w /dev/tty ]]; then printf '%s' "$1" >/dev/tty
  else printf '%s' "$1" >&2
  fi
}
# Render argv as a copy-pasteable line; quote args with shell-special chars and
# escape embedded single quotes ( ' -> '\'' ) so JSON/policy args render right.
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
# _confirm_cmd: print the command and ask y/Y (does NOT run it; declining aborts).
_confirm_cmd() {
  _msg_tty $'\n'"${C_CMD}\$ $(_render_cmd "$@")${C_OFF}"$'\n'
  _consent || die "Aborted by user (declined the command above)."
}
# confirm_run: print, ask, then execute. Safe inside VAR=$(confirm_run ...).
confirm_run() { _confirm_cmd "$@"; "$@"; }
# Idempotent SG ingress. MUTATING — gated (prompted once).
ensure_ingress() {
  _confirm_cmd aws ec2 authorize-security-group-ingress "$@"
  local out
  if out=$(aws ec2 authorize-security-group-ingress "$@" 2>&1); then return 0; fi
  case "$out" in *Duplicate*) return 0 ;; esac
  printf '%s\n' "$out" >&2; return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 0. Preflight + dependency install  (local tooling — NOT gated)
# ─────────────────────────────────────────────────────────────────────────────
log "Preflight checks"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
install_deps() {
  local pkgs=()
  for p in jq curl unzip zip; do command -v "$p" >/dev/null || pkgs+=("$p"); done
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
for b in aws jq curl zip; do command -v "$b" >/dev/null || die "'$b' not on PATH"; done
aws sts get-caller-identity >/dev/null 2>&1 || die "No usable AWS credentials"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ok "Account $ACCOUNT_ID / region $REGION"

echo "# SwiftCart Day3 state — generated $(date)" > "$STATE_FILE"
record REGION "$REGION"
record KEY_FILE "$KEY_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Discover Day 1/2 resources (fail clearly if the foundation is missing) — RO
# ─────────────────────────────────────────────────────────────────────────────
log "Discovering existing stack"
QUEUE_URL=$(aws sqs get-queue-url --queue-name OrderProcessingQueue --query 'QueueUrl' --output text 2>/dev/null || echo "")
[ -z "$QUEUE_URL" ] || [ "$QUEUE_URL" = "None" ] && die "OrderProcessingQueue not found — run Day 1 first."
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT}-Order-Fanout"
VPC_A=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-VPC-A-Public" "Vpcs[0].VpcId")
read -r WEB_ID WEB_IP < <(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=$PROJECT-WebPortal Name=instance-state-name,Values=running,pending,stopping,stopped \
  --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]' --output text)
INV_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Inventory Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PrivateIpAddress")
BASTION_IP=$(get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$PROJECT-Bastion Name=instance-state-name,Values=running,pending,stopping,stopped" "Reservations[0].Instances[0].PublicIpAddress")
ALB_DNS=$(get_id "aws elbv2 describe-load-balancers --names $PROJECT-External-ALB" "LoadBalancers[0].DNSName")
ok "Queue=OrderProcessingQueue  WebPortal=${WEB_ID:-?} ($WEB_IP)  Inventory=$INV_IP"

# ─────────────────────────────────────────────────────────────────────────────
# 2. IAM execution role for Lambda
# ─────────────────────────────────────────────────────────────────────────────
log "IAM role for Lambda"
LAMBDA_ROLE="$PROJECT-ServerlessProcessor-Role"
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  confirm_run aws iam create-role --role-name "$LAMBDA_ROLE" --assume-role-policy-document "$LAMBDA_TRUST" >/dev/null
fi
confirm_run aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole   # idempotent
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" --query 'Role.Arn' --output text)
record LAMBDA_ROLE "$LAMBDA_ROLE"
ok "Role $LAMBDA_ROLE_ARN"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Lambda function (packaged from the repo source — fetch/zip are local, ungated)
# ─────────────────────────────────────────────────────────────────────────────
log "Lambda function"
LAMBDA_NAME="$PROJECT-Order-Processor"
BUILD="$(mktemp -d)"
curl -fsSL "$REPO_RAW/src/lambda/lambda_function.py" -o "$BUILD/lambda_function.py"
( cd "$BUILD" && zip -q function.zip lambda_function.py )

if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  confirm_run aws lambda update-function-code --function-name "$LAMBDA_NAME" \
    --zip-file "fileb://$BUILD/function.zip" --query 'FunctionArn' --output text >/dev/null
  aws lambda wait function-updated --function-name "$LAMBDA_NAME"
else
  # Gate the create ONCE, then retry it silently — the freshly created role can
  # take a few seconds to become assumable (IAM propagation).
  CREATE_FN_ARGS=(aws lambda create-function --function-name "$LAMBDA_NAME"
    --runtime "$LAMBDA_RUNTIME" --architectures "$LAMBDA_ARCH"
    --role "$LAMBDA_ROLE_ARN" --handler lambda_function.lambda_handler
    --zip-file "fileb://$BUILD/function.zip"
    --timeout "$LAMBDA_TIMEOUT" --memory-size "$LAMBDA_MEMORY")
  _confirm_cmd "${CREATE_FN_ARGS[@]}"
  for i in 1 2 3 4 5 6; do
    if OUT=$("${CREATE_FN_ARGS[@]}" 2>&1); then break; fi
    if printf '%s' "$OUT" | grep -qiE 'cannot be assumed|InvalidParameterValueException'; then
      log "  waiting for IAM role to propagate… ($i)"; sleep 8; continue
    fi
    printf '%s\n' "$OUT" >&2; die "lambda create-function failed"
  done
  aws lambda wait function-active --function-name "$LAMBDA_NAME"
fi
rm -rf "$BUILD"
LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)
record LAMBDA_NAME "$LAMBDA_NAME"
ok "Lambda $LAMBDA_ARN ($LAMBDA_RUNTIME/$LAMBDA_ARCH, ${LAMBDA_TIMEOUT}s)"

# ─────────────────────────────────────────────────────────────────────────────
# 4. SQS -> Lambda event source mapping (with partial-batch-failure reporting)
# ─────────────────────────────────────────────────────────────────────────────
log "SQS event source mapping"
ESM_UUID=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_NAME" \
  --query "EventSourceMappings[?EventSourceArn=='$QUEUE_ARN'].UUID | [0]" --output text 2>/dev/null || echo "")
if [ -z "$ESM_UUID" ] || [ "$ESM_UUID" = "None" ]; then
  ESM_UUID=$(confirm_run aws lambda create-event-source-mapping --function-name "$LAMBDA_NAME" \
    --event-source-arn "$QUEUE_ARN" --batch-size 10 \
    --function-response-types ReportBatchItemFailures \
    --query 'UUID' --output text)
fi
record ESM_UUID "$ESM_UUID"
ok "Event source mapping $ESM_UUID (OrderProcessingQueue -> $LAMBDA_NAME, batch 10)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. CloudTrail (management-event auditing) + its S3 bucket
# ─────────────────────────────────────────────────────────────────────────────
log "CloudTrail"
TRAIL_NAME="$PROJECT-Management-Audit"
TRAIL_ARN="arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${TRAIL_NAME}"
CT_BUCKET="swiftcart-cloudtrail-${ACCOUNT_ID}-${REGION}"
if ! aws s3api head-bucket --bucket "$CT_BUCKET" >/dev/null 2>&1; then
  if [ "$REGION" = "us-east-1" ]; then
    confirm_run aws s3api create-bucket --bucket "$CT_BUCKET" >/dev/null
  else
    confirm_run aws s3api create-bucket --bucket "$CT_BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi
confirm_run aws s3api put-public-access-block --bucket "$CT_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
# Bucket policy allowing CloudTrail to write (scoped to this trail; no ACL clause —
# works with modern ACL-disabled buckets). Local /tmp file prep — NOT gated.
cat > /tmp/ct-bucket-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::$CT_BUCKET",
      "Condition": { "StringEquals": { "aws:SourceArn": "$TRAIL_ARN" } }
    },
    {
      "Sid": "AWSCloudTrailWrite",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$CT_BUCKET/AWSLogs/$ACCOUNT_ID/*",
      "Condition": { "StringEquals": { "aws:SourceArn": "$TRAIL_ARN" } }
    }
  ]
}
JSON
confirm_run aws s3api put-bucket-policy --bucket "$CT_BUCKET" --policy file:///tmp/ct-bucket-policy.json
if ! aws cloudtrail get-trail --name "$TRAIL_NAME" >/dev/null 2>&1; then
  confirm_run aws cloudtrail create-trail --name "$TRAIL_NAME" --s3-bucket-name "$CT_BUCKET" \
    --is-multi-region-trail --include-global-service-events >/dev/null
fi
confirm_run aws cloudtrail start-logging --name "$TRAIL_NAME"   # idempotent
record CT_BUCKET "$CT_BUCKET"; record TRAIL_NAME "$TRAIL_NAME"
ok "CloudTrail $TRAIL_NAME logging to s3://$CT_BUCKET"

# ─────────────────────────────────────────────────────────────────────────────
# 6. CloudWatch alarm on SQS queue depth -> SRE SNS topic
# ─────────────────────────────────────────────────────────────────────────────
log "CloudWatch alarm + SRE topic"
SRE_TOPIC_ARN=$(confirm_run aws sns create-topic --name "$PROJECT-SRE-Alerts" --query 'TopicArn' --output text)  # idempotent
record SRE_TOPIC_ARN "$SRE_TOPIC_ARN"
if [ "$NOTIFY_EMAIL" != "CHANGE_ME@example.com" ]; then
  EXIST_MAIL=$(aws sns list-subscriptions-by-topic --topic-arn "$SRE_TOPIC_ARN" \
    --query "Subscriptions[?Endpoint=='$NOTIFY_EMAIL'].SubscriptionArn | [0]" --output text 2>/dev/null || echo "")
  if [ -z "$EXIST_MAIL" ] || [ "$EXIST_MAIL" = "None" ]; then
    confirm_run aws sns subscribe --topic-arn "$SRE_TOPIC_ARN" --protocol email --notification-endpoint "$NOTIFY_EMAIL" >/dev/null
    ok "SRE email subscription created — confirm the link sent to $NOTIFY_EMAIL"
  fi
else
  warn "NOTIFY_EMAIL not set — alarm created but no email will be delivered (set NOTIFY_EMAIL to enable)"
fi
confirm_run aws cloudwatch put-metric-alarm --alarm-name SQS-Queue-Depth-Critical \
  --alarm-description "Order backlog: SQS consumers (Lambda) not keeping up" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value=OrderProcessingQueue \
  --statistic Maximum --period 60 --evaluation-periods 1 \
  --threshold 100 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching --alarm-actions "$SRE_TOPIC_ARN"   # idempotent (overwrites)
ok "Alarm SQS-Queue-Depth-Critical (>=100 msgs) -> $PROJECT-SRE-Alerts"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Containerise the Web Portal (Docker) — cutover from the Day 1 systemd service
# ─────────────────────────────────────────────────────────────────────────────
print_manual_docker() {
  cat <<MANUAL

  Run the Docker cutover manually if it was skipped/failed. SSH to the Web Portal
  (ProxyCommand form — a plain 'ssh -J' can drop -i on the jump; absolute key path):
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$WEB_IP
  then, on the Web Portal:
    sudo systemctl disable --now swiftcart-web          # free port 80 (Day 1 service)
    sudo amazon-linux-extras install docker -y && sudo systemctl enable --now docker
    sudo curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    mkdir -p ~/swiftcart_docker && cd ~/swiftcart_docker
    curl -fsSL $REPO_RAW/src/web-portal/web_portal.py    -o web_portal.py
    curl -fsSL $REPO_RAW/src/web-portal/Dockerfile       -o Dockerfile
    curl -fsSL $REPO_RAW/src/web-portal/requirements.txt -o requirements.txt
    # create docker-compose.yml with AWS_REGION/SNS_TOPIC_ARN/INVENTORY_API_URL, then:
    sudo docker-compose up -d --build
  Also set the metadata hop limit so the container can read the IAM role:
    aws ec2 modify-instance-metadata-options --instance-id $WEB_ID --http-put-response-hop-limit 2 --http-endpoint enabled
MANUAL
}

do_docker_cutover() {
  [ -f "$KEY_FILE" ] || { warn "Key $KEY_FILE not found — skipping Docker cutover"; return 1; }
  [ -n "$BASTION_IP" ] && [ "$BASTION_IP" != "None" ] || { warn "No bastion IP — skipping"; return 1; }
  [ -n "${WEB_ID:-}" ] && [ "$WEB_ID" != "None" ] || { warn "Web Portal instance not found — skipping"; return 1; }
  chmod 400 "$KEY_FILE" 2>/dev/null || true

  # Containers add a network hop; allow IMDS at hop limit 2 so boto3 finds the role
  confirm_run aws ec2 modify-instance-metadata-options --instance-id "$WEB_ID" \
    --http-put-response-hop-limit 2 --http-endpoint enabled >/dev/null
  ok "IMDS hop limit set to 2 on the Web Portal (container credential access)"

  # Ensure this host can SSH to the bastion (MUTATING — gated)
  local myip sgb
  myip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]' || echo "")
  sgb=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=SG-BastionHost Name=vpc-id,Values=$VPC_A" "SecurityGroups[0].GroupId")
  if [ -n "$myip" ] && [ -n "$sgb" ]; then
    ensure_ingress --group-id "$sgb" --protocol tcp --port 22 --cidr "${myip}/32" || true
  fi

  # The remote cutover script (runs on the Web Portal). Positional args $1..$5 are
  # passed on the ssh command line below; the heredoc body stays literal.
  local remote_script
  remote_script=$(cat <<'REMOTE'
set -e
SNS_ARN="$1"; INV_IP="$2"; REPO="$3"; REG="$4"; DCVER="$5"

# Free port 80: the Day 1 app runs under systemd (Restart=always) — pkill alone
# won't stick, so disable the unit.
sudo systemctl disable --now swiftcart-web 2>/dev/null || true
sudo pkill -f web_portal.py 2>/dev/null || true

# Docker engine + compose
if ! command -v docker >/dev/null 2>&1; then
  sudo amazon-linux-extras install docker -y
fi
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user 2>/dev/null || true
if ! command -v docker-compose >/dev/null 2>&1 && [ ! -x /usr/local/bin/docker-compose ]; then
  sudo curl -L "https://github.com/docker/compose/releases/download/$DCVER/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# App build context (pulled from the repo)
mkdir -p ~/swiftcart_docker && cd ~/swiftcart_docker
curl -fsSL "$REPO/src/web-portal/web_portal.py"    -o web_portal.py
curl -fsSL "$REPO/src/web-portal/Dockerfile"       -o Dockerfile
curl -fsSL "$REPO/src/web-portal/requirements.txt" -o requirements.txt

# Runtime config. Credentials come from the EC2 IAM role via IMDS (hop limit 2),
# so no ~/.aws bind-mount is needed.
cat > docker-compose.yml <<COMPOSE
version: '3.8'
services:
  web_portal:
    build: .
    image: swiftcart-web:latest
    container_name: swiftcart_web_container
    ports:
      - "80:80"
    restart: always
    environment:
      - AWS_REGION=$REG
      - AWS_DEFAULT_REGION=$REG
      - SNS_TOPIC_ARN=$SNS_ARN
      - INVENTORY_API_URL=http://$INV_IP:5000/api/v1/inventory
COMPOSE

sudo /usr/local/bin/docker-compose up -d --build
sleep 4
sudo docker ps --filter name=swiftcart_web_container --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "--- local health check ---"
curl -fsS http://localhost/health || echo "(health not ready yet — ALB will re-check)"
REMOTE
)

  # Print the exact remote action and get consent before touching the instance.
  _msg_tty $'\n'"${C_CMD}\$ ssh -o ProxyCommand=\"ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP\" -i $KEY_FILE ec2-user@$WEB_IP \\
      bash -s -- '$TOPIC_ARN' '$INV_IP' '$REPO_RAW' '$REGION' '$COMPOSE_VERSION' <<'REMOTE'${C_OFF}"$'\n'
  _msg_tty "$remote_script"$'\n'
  _msg_tty "${C_CMD}REMOTE${C_OFF}"$'\n'
  if ! _consent; then _msg_tty "    (skipped by user)"$'\n'; return 2; fi

  log "Cutting the Web Portal over to Docker (this pulls images + builds — ~2 min)…"
  printf '%s\n' "$remote_script" | ssh -i "$KEY_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
    -o "ProxyCommand=ssh -i $KEY_FILE -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -W %h:%p ec2-user@$BASTION_IP" \
    "ec2-user@$WEB_IP" \
    "bash -s -- '$TOPIC_ARN' '$INV_IP' '$REPO_RAW' '$REGION' '$COMPOSE_VERSION'"
  return $?
}

if [ "$DO_DOCKER" = "true" ]; then
  log "Docker cutover (over bastion)"
  if do_docker_cutover; then ok "Web Portal now serving from the Docker container"; else warn "Docker cutover incomplete — see manual steps"; print_manual_docker; fi
else
  warn "DO_DOCKER=false — skipping container cutover"; print_manual_docker
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
cat <<SUMMARY

════════════════════════════════════════════════════════════════════
  SwiftCart Day 3 — provisioning complete
════════════════════════════════════════════════════════════════════
  Lambda        : $LAMBDA_NAME  ($LAMBDA_RUNTIME/$LAMBDA_ARCH)
  Event source  : OrderProcessingQueue -> Lambda (batch 10, partial failures)
  CloudTrail    : $TRAIL_NAME  -> s3://$CT_BUCKET
  CloudWatch    : SQS-Queue-Depth-Critical (>=100) -> $PROJECT-SRE-Alerts
  Web Portal    : containerised (swiftcart_web_container on :80)

  Validate the serverless pipeline (via the ALB or the Day 2 CloudFront URL):
    curl http://$ALB_DNS/health
    curl -X POST http://$ALB_DNS/checkout \\
      -H 'Content-Type: application/json' \\
      -d '{"sku":"SKU-9999","quantity":1,"email":"sre@swiftcart.com"}'
    # then watch the Lambda logs:
    aws logs tail /aws/lambda/$LAMBDA_NAME --follow --region $REGION

  Audit trail (who deleted what):
    aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteEventSourceMapping --region $REGION
SUMMARY

# SSH help — concrete only when the key is actually on this host. ProxyCommand
# form because some OpenSSH builds don't pass -i to a '-J' jump host.
if [ -f "$KEY_FILE" ]; then
  cat <<SSHHELP

  Inspect the container on the Web Portal (ProxyCommand form — a plain 'ssh -J'
  can drop -i on the jump):
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$WEB_IP
    # on the box:  sudo docker ps ; sudo docker logs swiftcart_web_container
SSHHELP
else
  cat <<SSHHELP

  SSH: ${KEY_NAME}.pem is NOT on this host ($KEY_FILE) — the Docker cutover was
  skipped. The key is created by Day 1; get it here, then re-run with DO_DOCKER=true:
    f=\$(find / -name ${KEY_NAME}.pem 2>/dev/null | head -1); \\
      [ -n "\$f" ] && cp "\$f" $KEY_FILE && chmod 400 $KEY_FILE && echo "restored from \$f" \\
      || echo "no local copy — copy ${KEY_NAME}.pem here (scp), or see Day 1 output to rotate"
    # then connect (ProxyCommand form):
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" -i $KEY_FILE ec2-user@$WEB_IP
SSHHELP
fi

cat <<SUMMARY

  NOTE: the containerised portal serves /health and /checkout only (no /product).
  State saved to: $STATE_FILE
  Tear down Day 3 with: ./swiftcart-day3-teardown.sh   (leaves Day 1 & 2 intact)
════════════════════════════════════════════════════════════════════
SUMMARY
