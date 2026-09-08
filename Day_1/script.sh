#!/usr/bin/env bash
###############################################################################
# SwiftCart — Day 1: Zero-Trust Backbone & Messaging Federation
# Automated provisioning of the entire lab via AWS CLI.
#
# This reproduces every manual console step from the Day 1 guide:
#   VPC A (public/DMZ) + VPC B (dark/private), subnets, IGW, central NAT,
#   route tables, Transit Gateway (+attachments+routes), zero-trust security
#   groups, PrivateLink endpoints (SQS in B / SNS in A), IAM instance roles,
#   SNS->SQS fan-out (+email sub), EC2 (Bastion/Inventory/WebPortal) and an ALB.
#   The EC2 instances deploy the real SwiftCart apps (from the repo) on boot.
#
# PREREQUISITES
#   - Ubuntu/Debian host with sudo (or run as root). Missing tools — AWS CLI v2,
#     jq, curl, unzip — are installed automatically (set AUTO_INSTALL_DEPS=false
#     to disable). On non-apt distros, install them yourself first.
#   - Credentials: an attached IAM instance profile is picked up automatically;
#     otherwise run `aws configure` (or set env creds) first. Either way the
#     identity needs rights to create VPC/TGW/IAM/SNS/SQS/EC2/ELB resources.
#   - You EDIT the CONFIG block below (at minimum NOTIFY_EMAIL)
#
# USAGE
#   chmod +x swiftcart-day1-provision.sh
#   ./swiftcart-day1-provision.sh            # interactive: approve each command
#   ./swiftcart-day1-provision.sh -y         # non-interactive: auto-approve all
#   ./swiftcart-day1-provision.sh --help     # show flags and env overrides
#
# INTERACTIVE CONSENT (build path)
#   Every RESOURCE-CREATING or MUTATING AWS command is printed verbatim and must
#   be confirmed with 'y' or 'Y' before it executes. Read-only describe/list/get/
#   wait calls, local tool installs, and local file prep (jq -> /tmp) run without
#   prompting. Prompts are written to the controlling terminal (/dev/tty), so
#   they survive command substitution ( VAR=$(...) ) and stderr/stdout capture.
#   Declining any prompted command aborts the run.
#   Pass -y / --yes (or set ASSUME_YES=true) to auto-approve every prompt for a
#   fully non-interactive run — commands are still printed before they execute:
#     ./swiftcart-day1-provision.sh -y
#     ASSUME_YES=true ./swiftcart-day1-provision.sh
#   Idempotent helpers only prompt when they actually create something; the
#   authorize/route/associate helpers tolerate duplicates, so on a converging
#   re-run you may approve calls that turn out to be no-ops.
#
# NOTES / DEVIATIONS FROM THE DOC (read these):
#   1. SNS endpoint is placed in VPC A and SQS endpoint in VPC B — this matches
#      the doc's later, detailed section (Web Portal in A publishes to SNS;
#      Inventory in B consumes from SQS). The earlier one-liner was ambiguous.
#   2. SG-InventoryService's SSH rule uses VPC A's CIDR instead of referencing
#      SG-BastionHost by ID. Cross-VPC security-group references do NOT work
#      over a Transit Gateway (only over VPC peering), so the console approach
#      would fail here. Same admin-via-bastion intent, expressed as a CIDR.
#   3. IDEMPOTENT / RE-RUNNABLE: every resource is looked up by Name tag (or
#      name) before creation and reused if it already exists, and duplicate
#      rules/routes/associations are tolerated. Safe to re-run after a failure.
#      Caveat: EC2 user-data only runs at first boot — if an instance already
#      exists its app is NOT redeployed. Terminate it (or run teardown) to
#      force a fresh deploy. Resource IDs are (re)written to ./swiftcart-state.env.
#
# COST WARNING: NAT Gateway, Transit Gateway, ALB, interface endpoints and the
# EC2 instances all bill by the hour. Run the teardown script when you're done.
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG  — edit these
# ─────────────────────────────────────────────────────────────────────────────
REGION="${REGION:-us-east-1}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-samarth.sharma@scaler.com}"   # <-- REQUIRED: your email for SNS
KEY_NAME="${KEY_NAME:-swiftcart-key}"                   # created automatically if missing
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"              # t2.micro = classic free tier
ADMIN_CIDR="${ADMIN_CIDR:-}"                            # e.g. 203.0.113.4/32; blank = auto-detect
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-true}"         # auto-install aws/jq/curl/unzip if missing
ASSUME_YES="${ASSUME_YES:-false}"                      # true = auto-approve every consent prompt
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kubeboiii/swiftcart-aws/main}"  # app source
PROJECT="SwiftCart"

# Derived
export AWS_DEFAULT_REGION="$REGION"
AZ1="${REGION}a"
AZ2="${REGION}b"
STATE_FILE="./swiftcart-state.env"

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

Environment overrides (all optional): REGION, NOTIFY_EMAIL, KEY_NAME,
INSTANCE_TYPE, ADMIN_CIDR, AUTO_INSTALL_DEPS, ASSUME_YES, REPO_RAW.
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
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }
record() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }   # persist an ID for teardown

tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT}]"; }

# ─────────────────────────────────────────────────────────────────────────────
# Interactive consent  (build path — declining any prompt aborts the run)
# ─────────────────────────────────────────────────────────────────────────────
# Every RESOURCE-CREATING / MUTATING command is echoed exactly and must be
# approved with 'y' / 'Y'. Prompts/echoes go to the controlling terminal
# (/dev/tty), so they survive command substitution ( VAR=$(...) ) and 2>&1
# capture used by the idempotent wrappers below.
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
# single quotes are escaped ( ' -> '\'' ) so tag specs, JSON docs and the EC2
# user-data (which DO contain single quotes) render correctly.
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
    _msg_tty "    (auto-approved via ASSUME_YES=true)"$'\n'; return 0
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
# Declining aborts the whole script (die). Use this inside the idempotent
# wrappers that must capture the command's own stdout/stderr themselves.
_confirm_cmd() {
  _msg_tty $'\n'"${C_CMD}\$ $(_render_cmd "$@")${C_OFF}"$'\n'
  _consent || die "Aborted by user (declined the command above)."
}

# confirm_run <argv...> : print the command, ask y/Y, then execute it. Caller
# redirections/pipes apply to the command; the prompt goes to /dev/tty. Safe
# inside VAR=$(confirm_run ...) — only the command's stdout is captured.
confirm_run() { _confirm_cmd "$@"; "$@"; }

# get_id "<describe cmd + filters>" "<jmespath>"  -> existing id, or empty string.
# NOTE: query must not contain backticks or single quotes (eval-sensitive).
# READ-ONLY — never gated.
get_id() {
  local out
  out=$(eval "$1 --query '$2' --output text" 2>/dev/null) || out=""
  [ "$out" = "None" ] && out=""
  printf '%s' "$out"
}

# run_ok "<benign-error regex>" <cmd...>  -> succeed if cmd works OR fails benignly.
# MUTATING — gated.
run_ok() {
  local pat="$1"; shift
  _confirm_cmd "$@"
  local out
  if out=$("$@" 2>&1); then return 0; fi
  if printf '%s' "$out" | grep -qiE "$pat"; then return 0; fi
  printf '%s\n' "$out" >&2; return 1
}

# Idempotent security-group ingress (ignores duplicate rules). MUTATING — gated.
ensure_ingress() {
  _confirm_cmd aws ec2 authorize-security-group-ingress "$@"
  local out
  if out=$(aws ec2 authorize-security-group-ingress "$@" 2>&1); then return 0; fi
  case "$out" in *Duplicate*) return 0 ;; esac
  printf '%s\n' "$out" >&2; return 1
}

# Idempotent route (create, or replace if it already exists). MUTATING — gated.
# (The replace-route fallback achieves the same end state you just approved,
#  so it is not prompted a second time.)
ensure_route() {  # ensure_route <rt-id> <cidr> <target-flag> <target-id>
  local rt="$1" cidr="$2" flag="$3" tgt="$4" out
  _confirm_cmd aws ec2 create-route --route-table-id "$rt" --destination-cidr-block "$cidr" "$flag" "$tgt"
  if out=$(aws ec2 create-route --route-table-id "$rt" --destination-cidr-block "$cidr" "$flag" "$tgt" 2>&1); then
    return 0
  fi
  if printf '%s' "$out" | grep -qi 'RouteAlreadyExists'; then
    aws ec2 replace-route --route-table-id "$rt" --destination-cidr-block "$cidr" "$flag" "$tgt" >/dev/null 2>&1 || true
    return 0
  fi
  printf '%s\n' "$out" >&2; return 1
}

# Idempotent subnet<->route-table association (ignores already-associated).
# MUTATING — gated.
ensure_assoc() {  # ensure_assoc <rt-id> <subnet-id>
  _confirm_cmd aws ec2 associate-route-table --route-table-id "$1" --subnet-id "$2"
  local out
  if out=$(aws ec2 associate-route-table --route-table-id "$1" --subnet-id "$2" 2>&1); then return 0; fi
  if printf '%s' "$out" | grep -qi 'AlreadyAssociated'; then return 0; fi
  printf '%s\n' "$out" >&2; return 1
}

wait_state() {  # wait_state "<describe cmd>" "<jmespath>" "<target>"   READ-ONLY — never gated
  local desc="$1" query="$2" target="$3" st
  while true; do
    st=$(eval "$desc --query '$query' --output text" 2>/dev/null || echo "pending")
    [ "$st" = "$target" ] && return 0
    [ "$st" = "failed" ] && die "resource entered 'failed' state"
    sleep 12
  done
}

# ── get-or-create wrappers for the tagged EC2/VPC resources ──────────────────
# Only the create branch is gated (lookups are read-only). confirm_run inside
# $(...) prints to /dev/tty and returns just the new id on stdout.
ensure_vpc() {  # ensure_vpc <cidr> <name>
  local id; id=$(get_id "aws ec2 describe-vpcs --filters Name=tag:Name,Values=$2" "Vpcs[0].VpcId")
  [ -z "$id" ] && id=$(confirm_run aws ec2 create-vpc --cidr-block "$1" \
      --tag-specifications "$(tag vpc "$2")" --query 'Vpc.VpcId' --output text)
  printf '%s' "$id"
}
ensure_subnet() {  # ensure_subnet <vpc> <cidr> <az> <name>
  local id; id=$(get_id "aws ec2 describe-subnets --filters Name=tag:Name,Values=$4 Name=vpc-id,Values=$1" "Subnets[0].SubnetId")
  [ -z "$id" ] && id=$(confirm_run aws ec2 create-subnet --vpc-id "$1" --cidr-block "$2" --availability-zone "$3" \
      --tag-specifications "$(tag subnet "$4")" --query 'Subnet.SubnetId' --output text)
  printf '%s' "$id"
}
ensure_rt() {  # ensure_rt <vpc> <name>
  local id; id=$(get_id "aws ec2 describe-route-tables --filters Name=tag:Name,Values=$2 Name=vpc-id,Values=$1" "RouteTables[0].RouteTableId")
  [ -z "$id" ] && id=$(confirm_run aws ec2 create-route-table --vpc-id "$1" \
      --tag-specifications "$(tag route-table "$2")" --query 'RouteTable.RouteTableId' --output text)
  printf '%s' "$id"
}
ensure_sg() {  # ensure_sg <name> <desc> <vpc>
  local id; id=$(get_id "aws ec2 describe-security-groups --filters Name=group-name,Values=$1 Name=vpc-id,Values=$3" "SecurityGroups[0].GroupId")
  [ -z "$id" ] && id=$(confirm_run aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$3" \
      --tag-specifications "$(tag security-group "$1")" --query 'GroupId' --output text)
  printf '%s' "$id"
}
ensure_endpoint() {  # ensure_endpoint <name> <vpc> <service> <subnet> <sg>
  local id; id=$(get_id "aws ec2 describe-vpc-endpoints --filters Name=tag:Name,Values=$1 Name=vpc-endpoint-state,Values=available,pending,pendingAcceptance" "VpcEndpoints[0].VpcEndpointId")
  [ -z "$id" ] && id=$(confirm_run aws ec2 create-vpc-endpoint --vpc-endpoint-type Interface \
      --vpc-id "$2" --service-name "$3" --subnet-ids "$4" --security-group-ids "$5" --private-dns-enabled \
      --tag-specifications "$(tag vpc-endpoint "$1")" --query 'VpcEndpoint.VpcEndpointId' --output text)
  printf '%s' "$id"
}
instance_id() {  # instance_id <name-tag>   READ-ONLY — never gated
  get_id "aws ec2 describe-instances --filters Name=tag:Name,Values=$1 Name=instance-state-name,Values=pending,running,stopping,stopped" "Reservations[0].Instances[0].InstanceId"
}

# ─────────────────────────────────────────────────────────────────────────────
# 0. Preflight
# ─────────────────────────────────────────────────────────────────────────────
log "Preflight checks"

# Use sudo only when not already root
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

install_deps() {   # local tooling only — NOT gated (matches build-path policy)
  local apt_pkgs=()
  command -v jq    >/dev/null || apt_pkgs+=(jq)
  command -v curl  >/dev/null || apt_pkgs+=(curl)
  command -v unzip >/dev/null || apt_pkgs+=(unzip)
  if [ "${#apt_pkgs[@]}" -gt 0 ]; then
    command -v apt-get >/dev/null || die "missing ${apt_pkgs[*]} and no apt-get to install them — install manually"
    log "Installing packages: ${apt_pkgs[*]}"
    $SUDO apt-get update -y -qq
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_pkgs[@]}"
  fi
  # AWS CLI v2 (apt 'awscli' is the outdated v1 — install the official v2)
  if ! command -v aws >/dev/null; then
    log "Installing AWS CLI v2…"
    local url tmp
    case "$(uname -m)" in
      x86_64)  url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
      aarch64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
      *) die "unsupported architecture $(uname -m) — install AWS CLI v2 manually" ;;
    esac
    tmp="$(mktemp -d)"
    curl -fsSL "$url" -o "$tmp/awscliv2.zip"
    unzip -q "$tmp/awscliv2.zip" -d "$tmp"
    $SUDO "$tmp/aws/install" --update
    rm -rf "$tmp"
    hash -r
  fi
}

if [ "$AUTO_INSTALL_DEPS" = "true" ]; then
  install_deps
fi

for bin in aws jq curl; do
  command -v "$bin" >/dev/null || die "'$bin' still not on PATH (set AUTO_INSTALL_DEPS=true or install it manually)"
done
aws sts get-caller-identity >/dev/null 2>&1 || \
  die "No usable AWS credentials — attach an IAM instance profile to this host or run 'aws configure'"

# NOTIFY_EMAIL guard (fixed): the old check compared against a placeholder that
# is never the default, so it never fired. Validate for real instead — empty or
# obviously-unset values abort; anything email-shaped (incl. the built-in
# default) is accepted. Override with NOTIFY_EMAIL=you@example.com.
case "$NOTIFY_EMAIL" in
  ""|*CHANGE_ME*|*example.com)
    die "Set NOTIFY_EMAIL (env var or CONFIG block) to your own email before running." ;;
  *@*.*) : ;;                                   # looks like an email — accept
  *) die "NOTIFY_EMAIL='$NOTIFY_EMAIL' doesn't look like an email address." ;;
esac

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ok "Account $ACCOUNT_ID / region $REGION"

# Duplicate guard: tag-based idempotency needs at most one resource per Name.
# Earlier non-idempotent runs can leave duplicate VPCs, which would pair a VPC
# from one run with an IGW/RT from another. Detect and stop with clear guidance.
for nm in "$PROJECT-VPC-A-Public" "$PROJECT-VPC-B-Private"; do
  cnt=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$nm" --query 'Vpcs[].VpcId' --output text 2>/dev/null | wc -w)
  [ "$cnt" -gt 1 ] && die "Found $cnt VPCs tagged '$nm' (duplicates from earlier runs). Run ./swiftcart-nuke.sh to clean up, then re-run this script."
done

# (Re)generate the state file each run — every id below is rediscovered or created
echo "# SwiftCart Day1 state — generated $(date)"  > "$STATE_FILE"
record REGION "$REGION"

# Admin CIDR for bastion SSH
if [ -z "$ADMIN_CIDR" ]; then
  MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
  ADMIN_CIDR="${MY_IP}/32"
fi
ok "Bastion SSH will be allowed from $ADMIN_CIDR"

# SSH key pair
# NOTE: AWS only ever hands back the private key ONCE, at create-key-pair time.
# So the trap to avoid is: the key pair still exists in AWS (this check passes)
# but the local <name>.pem is gone — the instances get keyed to a key you can no
# longer authenticate with, and SSH fails with "Permission denied (publickey)".
# We create the pair only when it is absent in AWS, and loudly flag the mismatch
# case so you can rotate instead of getting silently locked out.
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  log "Creating key pair $KEY_NAME"
  confirm_run aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  ok "Saved ${KEY_NAME}.pem (keep it safe)"
else
  ok "Using existing key pair $KEY_NAME"
  if [ ! -f "${KEY_NAME}.pem" ]; then
    printf '\033[1;33m[warn]\033[0m %s\n' "Key pair '$KEY_NAME' exists in AWS, but ${KEY_NAME}.pem is not in $(pwd)." >&2
    printf '\033[1;33m[warn]\033[0m %s\n' "AWS cannot re-export a private key, so SSH will fail unless you already hold the original .pem." >&2
    printf '\033[1;33m[warn]\033[0m %s\n' "To rotate: aws ec2 delete-key-pair --key-name $KEY_NAME  — then re-run this script (a fresh .pem is written) and terminate the EC2 instances so they relaunch keyed to it." >&2
  else
    chmod 400 "${KEY_NAME}.pem" 2>/dev/null || true
  fi
fi
# Absolute path to the private key — used verbatim in the SSH help below so the
# printed command works regardless of which directory you paste it into.
KEY_FILE="$PWD/${KEY_NAME}.pem"
record KEY_NAME "$KEY_NAME"
record KEY_FILE "$KEY_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# 1. VPCs (+ DNS resolution/hostnames — required for private DNS on endpoints)
# ─────────────────────────────────────────────────────────────────────────────
log "VPCs"
VPC_A=$(ensure_vpc 10.10.0.0/16 "$PROJECT-VPC-A-Public")
VPC_B=$(ensure_vpc 10.20.0.0/16 "$PROJECT-VPC-B-Private")
for v in "$VPC_A" "$VPC_B"; do
  aws ec2 wait vpc-available --vpc-ids "$v"
  confirm_run aws ec2 modify-vpc-attribute --vpc-id "$v" --enable-dns-support  '{"Value":true}'   # idempotent
  confirm_run aws ec2 modify-vpc-attribute --vpc-id "$v" --enable-dns-hostnames '{"Value":true}'  # idempotent
done
record VPC_A "$VPC_A"; record VPC_B "$VPC_B"
ok "VPC A=$VPC_A (10.10/16)  VPC B=$VPC_B (10.20/16)"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Subnets
# ─────────────────────────────────────────────────────────────────────────────
log "Subnets"
SUB_A_PUB_1A=$(ensure_subnet "$VPC_A" 10.10.1.0/24 "$AZ1" VPC-A-Public-Subnet-1a)
SUB_A_PUB_1B=$(ensure_subnet "$VPC_A" 10.10.2.0/24 "$AZ2" VPC-A-Public-Subnet-1b)
SUB_A_TGW_1A=$(ensure_subnet "$VPC_A" 10.10.3.0/24 "$AZ1" VPC-A-TGW-Subnet-1a)
SUB_B_PRV_1A=$(ensure_subnet "$VPC_B" 10.20.1.0/24 "$AZ1" VPC-B-Private-Subnet-1a)
record SUB_A_PUB_1A "$SUB_A_PUB_1A"; record SUB_A_PUB_1B "$SUB_A_PUB_1B"
record SUB_A_TGW_1A "$SUB_A_TGW_1A"; record SUB_B_PRV_1A "$SUB_B_PRV_1A"
ok "4 subnets ready"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Internet Gateway + Elastic IP + central NAT Gateway
# ─────────────────────────────────────────────────────────────────────────────
log "Internet Gateway + NAT Gateway"
IGW=$(get_id "aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=$PROJECT-IGW" "InternetGateways[0].InternetGatewayId")
if [ -z "$IGW" ]; then
  IGW=$(confirm_run aws ec2 create-internet-gateway --tag-specifications "$(tag internet-gateway "$PROJECT-IGW")" \
    --query 'InternetGateway.InternetGatewayId' --output text)
fi
IGW_ATT=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW" \
  --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null || echo "")
if [ "$IGW_ATT" != "$VPC_A" ]; then
  run_ok "AlreadyAssociated|already attached" aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A"
fi
record IGW "$IGW"

EIP_ALLOC=$(get_id "aws ec2 describe-addresses --filters Name=tag:Name,Values=$PROJECT-NAT-EIP" "Addresses[0].AllocationId")
NAT=$(get_id "aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=$PROJECT-NAT Name=state,Values=available,pending" "NatGateways[0].NatGatewayId")
if [ -z "$NAT" ]; then
  if [ -z "$EIP_ALLOC" ]; then
    EIP_ALLOC=$(confirm_run aws ec2 allocate-address --domain vpc \
      --tag-specifications "$(tag elastic-ip "$PROJECT-NAT-EIP")" --query 'AllocationId' --output text)
  fi
  NAT=$(confirm_run aws ec2 create-nat-gateway --subnet-id "$SUB_A_PUB_1A" --allocation-id "$EIP_ALLOC" \
    --tag-specifications "$(tag natgateway "$PROJECT-NAT")" --query 'NatGateway.NatGatewayId' --output text)
fi
record EIP_ALLOC "$EIP_ALLOC"; record NAT "$NAT"
log "Ensuring NAT gateway is available (up to ~2 min on first create)…"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"
ok "IGW=$IGW  NAT=$NAT"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Route tables (IGW + NAT + associations). TGW routes added later.
# ─────────────────────────────────────────────────────────────────────────────
log "Route tables"
RT_A_PUB=$(ensure_rt "$VPC_A" RT-VPC-A-Public)
RT_TGW=$(ensure_rt   "$VPC_A" RT-TGW-Subnet)
RT_B_PRV=$(ensure_rt "$VPC_B" RT-VPC-B-Private)
record RT_A_PUB "$RT_A_PUB"; record RT_TGW "$RT_TGW"; record RT_B_PRV "$RT_B_PRV"

ensure_route "$RT_A_PUB" 0.0.0.0/0 --gateway-id "$IGW"
ensure_assoc "$RT_A_PUB" "$SUB_A_PUB_1A"
ensure_assoc "$RT_A_PUB" "$SUB_A_PUB_1B"
ensure_route "$RT_TGW"   0.0.0.0/0 --nat-gateway-id "$NAT"
ensure_assoc "$RT_TGW"   "$SUB_A_TGW_1A"
ensure_assoc "$RT_B_PRV" "$SUB_B_PRV_1A"
ok "Route tables wired (IGW + NAT + associations)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Transit Gateway + attachments + routes
# ─────────────────────────────────────────────────────────────────────────────
log "Transit Gateway"
TGW=$(get_id "aws ec2 describe-transit-gateways --filters Name=tag:Name,Values=$PROJECT-TGW Name=state,Values=available,pending,modifying" "TransitGateways[0].TransitGatewayId")
if [ -z "$TGW" ]; then
  TGW=$(confirm_run aws ec2 create-transit-gateway --description "$PROJECT-TGW" \
    --tag-specifications "$(tag transit-gateway "$PROJECT-TGW")" \
    --query 'TransitGateway.TransitGatewayId' --output text)
fi
record TGW "$TGW"
wait_state "aws ec2 describe-transit-gateways --transit-gateway-ids $TGW" "TransitGateways[0].State" "available"
ok "TGW=$TGW available"

log "TGW attachments"
ensure_tgw_attach() {  # ensure_tgw_attach <name> <vpc> <subnet>
  local id; id=$(get_id "aws ec2 describe-transit-gateway-vpc-attachments --filters Name=tag:Name,Values=$1 Name=state,Values=available,pending,initiatingRequest,modifying" "TransitGatewayVpcAttachments[0].TransitGatewayAttachmentId")
  [ -z "$id" ] && id=$(confirm_run aws ec2 create-transit-gateway-vpc-attachment --transit-gateway-id "$TGW" \
      --vpc-id "$2" --subnet-ids "$3" \
      --tag-specifications "$(tag transit-gateway-attachment "$1")" \
      --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)
  printf '%s' "$id"
}
ATTACH_A=$(ensure_tgw_attach TGW-Attach-VPC-A "$VPC_A" "$SUB_A_TGW_1A")
ATTACH_B=$(ensure_tgw_attach TGW-Attach-VPC-B "$VPC_B" "$SUB_B_PRV_1A")
record ATTACH_A "$ATTACH_A"; record ATTACH_B "$ATTACH_B"
for a in "$ATTACH_A" "$ATTACH_B"; do
  wait_state "aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids $a" \
             "TransitGatewayVpcAttachments[0].State" "available"
done
ok "Both attachments available"

# TGW default route table: send all unknown traffic to VPC A (for NAT egress)
TGW_RT=$(aws ec2 describe-transit-gateways --transit-gateway-ids "$TGW" \
  --query 'TransitGateways[0].Options.AssociationDefaultRouteTableId' --output text)
record TGW_RT "$TGW_RT"
run_ok "already exists|Duplicate|AlreadyExists" aws ec2 create-transit-gateway-route \
  --transit-gateway-route-table-id "$TGW_RT" --destination-cidr-block 0.0.0.0/0 --transit-gateway-attachment-id "$ATTACH_A"

# VPC route-table entries that depend on the TGW existing
ensure_route "$RT_A_PUB" 10.20.0.0/16 --transit-gateway-id "$TGW"
ensure_route "$RT_B_PRV" 0.0.0.0/0    --transit-gateway-id "$TGW"
ok "TGW routes in place (A<->B via TGW; B egress -> A -> NAT)"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Zero-Trust Security Groups
# ─────────────────────────────────────────────────────────────────────────────
log "Security groups"
SG_BASTION=$(ensure_sg SG-BastionHost      "Bastion SSH entrypoint"        "$VPC_A")
SG_WEB=$(ensure_sg     SG-WebPortal        "Public web portal"             "$VPC_A")
SG_INV=$(ensure_sg     SG-InventoryService "Inventory microservice (B)"    "$VPC_B")
SG_VPCE_A=$(ensure_sg  SG-VPCEndpoints-A   "VPC A interface endpoints 443" "$VPC_A")
SG_VPCE_B=$(ensure_sg  SG-VPCEndpoints-B   "VPC B interface endpoints 443" "$VPC_B")
SG_ALB=$(ensure_sg     SG-ALB              "External ALB"                  "$VPC_A")
record SG_BASTION "$SG_BASTION"; record SG_WEB "$SG_WEB"; record SG_INV "$SG_INV"
record SG_VPCE_A "$SG_VPCE_A"; record SG_VPCE_B "$SG_VPCE_B"; record SG_ALB "$SG_ALB"

ensure_ingress --group-id "$SG_BASTION" --protocol tcp --port 22 --cidr "$ADMIN_CIDR"
ensure_ingress --group-id "$SG_WEB" --protocol tcp --port 80 --cidr 0.0.0.0/0
ensure_ingress --group-id "$SG_WEB" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$SG_BASTION}]"
ensure_ingress --group-id "$SG_INV" --protocol tcp --port 5000 --cidr 10.10.0.0/16
ensure_ingress --group-id "$SG_INV" --protocol tcp --port 22   --cidr 10.10.0.0/16
ensure_ingress --group-id "$SG_VPCE_A" --protocol tcp --port 443 --cidr 10.10.0.0/16
ensure_ingress --group-id "$SG_VPCE_B" --protocol tcp --port 443 --cidr 10.20.0.0/16
ensure_ingress --group-id "$SG_ALB" --protocol tcp --port 80 --cidr 0.0.0.0/0
ok "6 security groups configured"

# ─────────────────────────────────────────────────────────────────────────────
# 7. VPC Endpoints (PrivateLink):  SQS in VPC B, SNS in VPC A
# ─────────────────────────────────────────────────────────────────────────────
log "PrivateLink interface endpoints"
EP_SQS=$(ensure_endpoint SQS-Endpoint "$VPC_B" "com.amazonaws.${REGION}.sqs" "$SUB_B_PRV_1A" "$SG_VPCE_B")
EP_SNS=$(ensure_endpoint SNS-Endpoint "$VPC_A" "com.amazonaws.${REGION}.sns" "$SUB_A_PUB_1A" "$SG_VPCE_A")
record EP_SQS "$EP_SQS"; record EP_SNS "$EP_SNS"
for e in "$EP_SQS" "$EP_SNS"; do
  wait_state "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $e" "VpcEndpoints[0].State" "available"
done
ok "SQS endpoint=$EP_SQS (B)  SNS endpoint=$EP_SNS (A)"

# ─────────────────────────────────────────────────────────────────────────────
# 8. IAM roles + instance profiles (no long-lived keys — instance profiles only)
# ─────────────────────────────────────────────────────────────────────────────
log "IAM roles / instance profiles"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
SNS_POLICY="arn:aws:iam::aws:policy/AmazonSNSFullAccess"
SQS_POLICY="arn:aws:iam::aws:policy/AmazonSQSFullAccess"

mk_role() {  # mk_role <role-name> <policy-arn...>  (idempotent)
  local role="$1"; shift
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || \
    confirm_run aws iam create-role --role-name "$role" --assume-role-policy-document "$TRUST" >/dev/null
  local p
  for p in "$@"; do confirm_run aws iam attach-role-policy --role-name "$role" --policy-arn "$p"; done  # attach is idempotent
  aws iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1 || \
    confirm_run aws iam create-instance-profile --instance-profile-name "$role" >/dev/null
  local cur
  cur=$(aws iam get-instance-profile --instance-profile-name "$role" \
        --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || echo "")
  if [ "$cur" != "$role" ]; then
    confirm_run aws iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role"
  fi
  record ROLE "$role"
}
mk_role "$PROJECT-WebPortal-Role" "$SNS_POLICY" "$SQS_POLICY"
mk_role "$PROJECT-Inventory-Role" "$SQS_POLICY"
log "Waiting ~20s for IAM instance profiles to propagate…"
sleep 20
ok "Roles ready: $PROJECT-WebPortal-Role, $PROJECT-Inventory-Role"

# ─────────────────────────────────────────────────────────────────────────────
# 9. Messaging federation: SQS queue, SNS topic, subscriptions, queue policy
# ─────────────────────────────────────────────────────────────────────────────
log "SNS / SQS"
QUEUE_URL=$(confirm_run aws sqs create-queue --queue-name OrderProcessingQueue --query 'QueueUrl' --output text)  # idempotent
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
TOPIC_ARN=$(confirm_run aws sns create-topic --name "$PROJECT-Order-Fanout" --query 'TopicArn' --output text)  # idempotent
record QUEUE_URL "$QUEUE_URL"; record QUEUE_ARN "$QUEUE_ARN"; record TOPIC_ARN "$TOPIC_ARN"

# Allow the SNS topic to deliver into the queue (idempotent overwrite).
# jq writes a local file only — not gated; the set-queue-attributes call is.
jq -n --arg q "$QUEUE_ARN" --arg t "$TOPIC_ARN" '{Policy: ({
  Version:"2012-10-17",
  Statement:[{Effect:"Allow",Principal:{Service:"sns.amazonaws.com"},
    Action:"sqs:SendMessage",Resource:$q,
    Condition:{ArnEquals:{"aws:SourceArn":$t}}}]} | tostring)}' > /tmp/sqs-policy.json
confirm_run aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes file:///tmp/sqs-policy.json

# SQS subscription (subscribe is idempotent for sqs — returns the existing ARN)
SUB_SQS=$(confirm_run aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
  --notification-endpoint "$QUEUE_ARN" --return-subscription-arn --query 'SubscriptionArn' --output text)
# Email subscription (guarded — re-subscribing would send another confirmation email)
EXISTING_MAIL=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
  --query "Subscriptions[?Endpoint=='$NOTIFY_EMAIL'].SubscriptionArn | [0]" --output text 2>/dev/null || echo "")
if [ -z "$EXISTING_MAIL" ] || [ "$EXISTING_MAIL" = "None" ]; then
  SUB_MAIL=$(confirm_run aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
    --notification-endpoint "$NOTIFY_EMAIL" --query 'SubscriptionArn' --output text)
  ok "Email subscription created — confirm the link sent to $NOTIFY_EMAIL"
else
  SUB_MAIL="$EXISTING_MAIL"
  ok "Email subscription already present for $NOTIFY_EMAIL"
fi
record SUB_SQS "$SUB_SQS"; record SUB_MAIL "$SUB_MAIL"

# ─────────────────────────────────────────────────────────────────────────────
# 10. Compute: Bastion (A), Inventory (B, no public IP), Web Portal (A)
#     Instances self-install the real SwiftCart apps from the repo on first boot.
# ─────────────────────────────────────────────────────────────────────────────
log "EC2 instances"
AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-ebs \
  --query 'Parameters[0].Value' --output text)
ok "Amazon Linux 2 AMI=$AMI"

launch() {  # launch <name> <subnet> <sg> <public:true|false> [instance-profile] [user-data]
  local name="$1" subnet="$2" sg="$3" pub="$4" profile="${5:-}" userdata="${6:-}"
  local pubflag; [ "$pub" = "true" ] && pubflag="--associate-public-ip-address" || pubflag="--no-associate-public-ip-address"
  local iamflag=(); [ -n "$profile" ]  && iamflag=(--iam-instance-profile "Name=$profile")
  local udflag=();  [ -n "$userdata" ] && udflag=(--user-data "$userdata")   # CLI base64-encodes this
  confirm_run aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
    --subnet-id "$subnet" --security-group-ids "$sg" $pubflag "${iamflag[@]}" "${udflag[@]}" \
    --tag-specifications "$(tag instance "$name")" \
    --query 'Instances[0].InstanceId' --output text
}

# Inventory user-data: pull the Flask inventory service, point it at our region,
# run under systemd on :5000. Egress works via TGW -> VPC A NAT.
# CRITICAL: AL2 ships OpenSSL 1.0.2 → must pin urllib3<2 or boto3/requests fail to import.
INV_USERDATA=$(cat <<EOF
#!/bin/bash
set -xe
yum update -y
yum install -y python3 python3-pip
pip3 install --retries 5 flask boto3 'urllib3<2'
mkdir -p /opt/swiftcart
curl -fsSL --retry 5 --retry-delay 5 $REPO_RAW/src/inventory-service/inventory_service.py -o /opt/swiftcart/inventory_service.py
sed -i "s/REGION = 'us-west-2'/REGION = '$REGION'/" /opt/swiftcart/inventory_service.py
cat >/etc/systemd/system/swiftcart-inventory.service <<'UNIT'
[Unit]
Description=SwiftCart Inventory Service
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/swiftcart/inventory_service.py
Restart=always
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now swiftcart-inventory
EOF
)

EC2_BASTION=$(instance_id "$PROJECT-Bastion")
if [ -z "$EC2_BASTION" ]; then
  EC2_BASTION=$(launch "$PROJECT-Bastion" "$SUB_A_PUB_1A" "$SG_BASTION" true)
fi

EC2_INV=$(instance_id "$PROJECT-Inventory")
if [ -z "$EC2_INV" ]; then
  EC2_INV=$(launch "$PROJECT-Inventory" "$SUB_B_PRV_1A" "$SG_INV" false "$PROJECT-Inventory-Role" "$INV_USERDATA")
fi

# Web Portal needs the Inventory private IP (assigned at launch) for its read URL.
INV_IP=$(aws ec2 describe-instances --instance-ids "$EC2_INV" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
record INV_IP "$INV_IP"

EC2_WEB=$(instance_id "$PROJECT-WebPortal")
if [ -z "$EC2_WEB" ]; then
  WEB_USERDATA=$(cat <<EOF
#!/bin/bash
set -xe
yum update -y
yum install -y python3 python3-pip
pip3 install --retries 5 flask boto3 requests 'urllib3<2'
mkdir -p /opt/swiftcart
curl -fsSL --retry 5 --retry-delay 5 $REPO_RAW/src/web-portal/web_portal_ec2.py -o /opt/swiftcart/web_portal.py
sed -i "s/REGION = 'us-west-2'/REGION = '$REGION'/" /opt/swiftcart/web_portal.py
sed -i "s/YOUR_ACCOUNT_ID/$ACCOUNT_ID/" /opt/swiftcart/web_portal.py
sed -i "s/10.20.1.X/$INV_IP/" /opt/swiftcart/web_portal.py
cat >/etc/systemd/system/swiftcart-web.service <<'UNIT'
[Unit]
Description=SwiftCart Web Portal
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/swiftcart/web_portal.py
Restart=always
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now swiftcart-web
EOF
)
  EC2_WEB=$(launch "$PROJECT-WebPortal" "$SUB_A_PUB_1A" "$SG_WEB" true "$PROJECT-WebPortal-Role" "$WEB_USERDATA")
fi
record EC2_BASTION "$EC2_BASTION"; record EC2_INV "$EC2_INV"; record EC2_WEB "$EC2_WEB"
aws ec2 wait instance-running --instance-ids "$EC2_BASTION" "$EC2_INV" "$EC2_WEB"
ok "Bastion=$EC2_BASTION  Inventory=$EC2_INV ($INV_IP)  WebPortal=$EC2_WEB"

# ─────────────────────────────────────────────────────────────────────────────
# 11. Application Load Balancer -> Web Portal
# ─────────────────────────────────────────────────────────────────────────────
log "Application Load Balancer"
ALB_ARN=$(get_id "aws elbv2 describe-load-balancers --names $PROJECT-External-ALB" "LoadBalancers[0].LoadBalancerArn")
if [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(confirm_run aws elbv2 create-load-balancer --name "$PROJECT-External-ALB" \
    --type application --scheme internet-facing \
    --subnets "$SUB_A_PUB_1A" "$SUB_A_PUB_1B" --security-groups "$SG_ALB" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
TG_ARN=$(get_id "aws elbv2 describe-target-groups --names TG-WebPortal" "TargetGroups[0].TargetGroupArn")

# If a pre-existing TG-WebPortal is bound to the wrong VPC, it must be recreated.
# A listener that forwards to it blocks deletion (ResourceInUse), so drop the
# ALB's listeners first, then the target group. (Fixed: the old code called
# delete-target-group directly, which aborts under `set -e` when a listener
# still references the group.)
if [ -n "$TG_ARN" ]; then
  TG_VPC=$(aws elbv2 describe-target-groups \
    --target-group-arns "$TG_ARN" \
    --query 'TargetGroups[0].VpcId' \
    --output text)
  if [ "$TG_VPC" != "$VPC_A" ]; then
    warn_msg="Existing TG-WebPortal is in $TG_VPC, not $VPC_A — recreating"
    printf '\033[1;33m[warn]\033[0m %s\n' "$warn_msg"
    OLD_LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
      --query 'Listeners[].ListenerArn' --output text 2>/dev/null || echo "")
    for l in $OLD_LISTENERS; do
      [ -n "$l" ] && [ "$l" != "None" ] && confirm_run aws elbv2 delete-listener --listener-arn "$l" || true
    done
    confirm_run aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
    TG_ARN=""
  fi
fi

if [ -z "$TG_ARN" ]; then
  TG_ARN=$(confirm_run aws elbv2 create-target-group \
    --name TG-WebPortal \
    --protocol HTTP \
    --port 80 \
    --target-type instance \
    --vpc-id "$VPC_A" \
    --health-check-path /health \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
fi

# Converge the health check path even on a pre-existing target group (the apps
# serve /health, not / — a stale "/" check is what returns 502).
confirm_run aws elbv2 modify-target-group --target-group-arn "$TG_ARN" --health-check-path /health
confirm_run aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=$EC2_WEB"

LISTENER_ARN=$(get_id "aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN" "Listeners[0].ListenerArn")
if [ -z "$LISTENER_ARN" ]; then
  LISTENER_ARN=$(confirm_run aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --query 'Listeners[0].ListenerArn' --output text)
fi
record ALB_ARN "$ALB_ARN"; record TG_ARN "$TG_ARN"; record LISTENER_ARN "$LISTENER_ARN"
log "Waiting for ALB to become active…"
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
record ALB_DNS "$ALB_DNS"
ok "ALB active: http://$ALB_DNS"
ok "Instances install their apps on first boot — allow ~2-3 min before endpoints respond"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
BASTION_IP=$(aws ec2 describe-instances --instance-ids "$EC2_BASTION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat <<SUMMARY

════════════════════════════════════════════════════════════════════
  SwiftCart Day 1 — provisioning complete
════════════════════════════════════════════════════════════════════
  VPC A (public) : $VPC_A          VPC B (dark) : $VPC_B
  Transit GW     : $TGW
  ALB URL        : http://$ALB_DNS
  SNS topic      : $TOPIC_ARN
  SQS queue      : $QUEUE_URL

  Apps deploy via user-data on first boot (give them ~2-3 min), then test:
    # Web portal health (ALB health-check target):
    curl http://$ALB_DNS/health
    # CQRS read path: ALB -> WebPortal (A) -> TGW -> Inventory (B) :5000
    curl http://$ALB_DNS/product/SKU-1001
    # CQRS write path: publish to SNS -> SQS + email (watch for the email)
    curl -X POST http://$ALB_DNS/checkout \\
      -H 'Content-Type: application/json' \\
      -d '{"sku":"SKU-1001","quantity":1,"email":"$NOTIFY_EMAIL"}'

SUMMARY

# ── SSH help — printed as part of the summary, but only as a concrete, runnable
#    command when the private key is actually on THIS host. If the key pair
#    already existed in AWS, the "using existing" branch above wrote NO local
#    .pem, so $KEY_FILE won't exist here and a printed 'ssh -i $KEY_FILE …' would
#    fail with "Identity file … No such file or directory".
#    FORM: some OpenSSH builds do NOT pass -i to a '-J' jump host — the jump then
#    offers only ~/.ssh/id_* and dies "Permission denied (publickey)" at the
#    bastion (verbose: "no pubkey loaded from …; identity file … type -1"). So we
#    always use an explicit ProxyCommand with -i on BOTH hops.
if [ -f "$KEY_FILE" ]; then
  cat <<SSHHELP

  SSH into the dark Inventory host, hopping through the bastion. Use the
  ProxyCommand form (explicit identity on BOTH hops) — a plain 'ssh -J' can fail
  because some OpenSSH builds don't hand -i to the jump connection:
    ssh \\
      -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" \\
      -i $KEY_FILE \\
      ec2-user@$INV_IP
    # reach the bastion directly:  ssh -i $KEY_FILE ec2-user@$BASTION_IP
    # on the inventory host:       sudo systemctl status swiftcart-inventory

  For a one-shot 'ssh swiftcart-inventory', append this to ~/.ssh/config:
    Host swiftcart-bastion
        HostName $BASTION_IP
        User ec2-user
        IdentityFile $KEY_FILE
    Host swiftcart-inventory
        HostName $INV_IP
        User ec2-user
        IdentityFile $KEY_FILE
        ProxyJump swiftcart-bastion
SSHHELP
else
  cat <<SSHHELP

  SSH: the private key ${KEY_NAME}.pem is NOT at $KEY_FILE, and AWS cannot
  re-export a private key. Pick ONE of these — all are paste-ready:

  1) A copy may already be on THIS host — find it and put it in place:
       f=\$(find / -name ${KEY_NAME}.pem 2>/dev/null | head -1); \\
         [ -n "\$f" ] && cp "\$f" $KEY_FILE && chmod 400 $KEY_FILE && echo "restored from \$f" \\
         || echo "no local copy — use option 2 or 3"

  2) You still have it on another machine — copy it over (set <that-host>):
       scp <that-host>:${KEY_NAME}.pem $KEY_FILE && chmod 400 $KEY_FILE

  3) Rotate — no old key needed. Terminates & relaunches the 3 instances, then
     re-runs this script, which writes a fresh ${KEY_NAME}.pem right here:
       aws ec2 terminate-instances --instance-ids $EC2_BASTION $EC2_INV $EC2_WEB
       aws ec2 wait instance-terminated --instance-ids $EC2_BASTION $EC2_INV $EC2_WEB
       aws ec2 delete-key-pair --key-name $KEY_NAME
       ./swiftcart-day1-provision.sh

  Then SSH in (ProxyCommand form — a plain 'ssh -J' can drop -i on the jump):
    ssh -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" \\
        -i $KEY_FILE ec2-user@$INV_IP
SSHHELP
fi

cat <<SUMMARY

  This script is re-runnable — re-run it to converge after any failure.
  (Existing EC2 instances keep their original app; terminate to redeploy.)
  ACTION REQUIRED: confirm the SNS email subscription sent to $NOTIFY_EMAIL
  All resource IDs saved to: $STATE_FILE
  Tear everything down with: ./swiftcart-day1-teardown.sh
════════════════════════════════════════════════════════════════════
SUMMARY
