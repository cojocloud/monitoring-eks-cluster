#!/usr/bin/env bash
# End-to-end cleanup: voting app → NLB → all Terraform-managed infrastructure
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/infrastructure"
STATE_BUCKET="cojocloud-terraform-state-bucket"

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━  $*  ━━━${NC}"; }
confirm() {
  local prompt="$1"
  read -rp "$(echo -e "${YELLOW}[?]${NC}    ${prompt} [y/N] ")" ans
  [[ "${ans,,}" == "y" ]]
}

# ─── Guard: confirm destructive intent ────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}WARNING: This script will permanently destroy:${NC}"
echo "  • The example voting app (namespace: vote)"
echo "  • The AWS Network Load Balancer provisioned by NGINX"
echo "  • The EKS cluster, VPC, subnets, IAM roles, and all managed resources"
echo ""
echo "  The S3 state bucket and any KMS keys are NOT deleted (see end of script)."
echo ""

confirm "Destroy all infrastructure? This cannot be undone." \
  || die "Aborted by user."

# ─── Read config ──────────────────────────────────────────────────────────────
TFVARS="$INFRA_DIR/terraform.tfvars"
if [[ -f "$TFVARS" ]]; then
  CLUSTER_NAME=$(grep 'cluster_name' "$TFVARS" | cut -d'"' -f2 || echo "CojoCloud-EKS-Cluster")
  AWS_REGION=$(  grep 'aws_region'   "$TFVARS" | cut -d'"' -f2 || echo "us-east-1")
else
  warn "terraform.tfvars not found — using default cluster name and region."
  CLUSTER_NAME="CojoCloud-EKS-Cluster"
  AWS_REGION="us-east-1"
fi

log "Cluster: $CLUSTER_NAME  |  Region: $AWS_REGION"

# ─── Step 1: AWS credentials ──────────────────────────────────────────────────
section "Step 1 — Validating AWS credentials"

aws sts get-caller-identity --output text --query 'Arn' \
  || die "AWS credentials not configured. Run: aws configure"
ok "Credentials valid."

# ─── Step 2: kubeconfig (best-effort) ─────────────────────────────────────────
section "Step 2 — Refreshing kubeconfig"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; then
  aws eks --region "$AWS_REGION" update-kubeconfig --name "$CLUSTER_NAME"
  ok "kubeconfig updated."
  CLUSTER_REACHABLE=true
else
  warn "Cluster '$CLUSTER_NAME' not found or not reachable — skipping kubeconfig update."
  CLUSTER_REACHABLE=false
fi

# ─── Step 3: Remove voting app ────────────────────────────────────────────────
section "Step 3 — Removing voting app"

if [[ "$CLUSTER_REACHABLE" == true ]] && kubectl get namespace vote &>/dev/null 2>&1; then
  kubectl delete namespace vote --wait=true
  ok "Namespace 'vote' deleted."
else
  log "Namespace 'vote' not found — nothing to delete."
fi

# ─── Step 4: Delete NLB(s) ────────────────────────────────────────────────────
section "Step 4 — Deleting Network Load Balancer(s)"

# Get the VPC ID associated with the EKS cluster so we only delete the right NLB
VPC_ID=""
if [[ "$CLUSTER_REACHABLE" == true ]]; then
  VPC_ID=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text 2>/dev/null || true)
fi

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  log "Cluster VPC: $VPC_ID"
  NLB_ARNS=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}' && Type=='network'].LoadBalancerArn" \
    --output text 2>/dev/null || true)
else
  warn "Could not determine VPC ID — falling back to tag-based NLB search."
  NLB_ARNS=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?Type=='network'].LoadBalancerArn" \
    --output text 2>/dev/null || true)
fi

if [[ -z "$NLB_ARNS" || "$NLB_ARNS" == "None" ]]; then
  log "No Network Load Balancers found — nothing to delete."
else
  for ARN in $NLB_ARNS; do
    NLB_NAME=$(aws elbv2 describe-load-balancers \
      --load-balancer-arns "$ARN" \
      --region "$AWS_REGION" \
      --query 'LoadBalancers[0].LoadBalancerName' \
      --output text 2>/dev/null || echo "unknown")
    log "Deleting NLB: $NLB_NAME ($ARN)"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" --region "$AWS_REGION"
  done

  log "Waiting for NLB deletion (up to 5 minutes)..."
  WAIT_SECS=0
  while true; do
    if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
      REMAINING=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "length(LoadBalancers[?VpcId=='${VPC_ID}' && Type=='network'])" \
        --output text 2>/dev/null || echo "0")
    else
      REMAINING=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "length(LoadBalancers[?Type=='network'])" \
        --output text 2>/dev/null || echo "0")
    fi
    [[ "$REMAINING" -eq 0 ]] && break
    [[ $WAIT_SECS -ge 300 ]] && { warn "NLB still not deleted after 5 min — continuing anyway."; break; }
    echo -n "."
    sleep 10
    (( WAIT_SECS += 10 ))
  done
  echo ""
  ok "NLB(s) deleted."
fi

# ─── Step 5: Terraform destroy ────────────────────────────────────────────────
section "Step 5 — Terraform destroy  (~10-15 min)"

cd "$INFRA_DIR"

# Ensure state bucket is accessible before running destroy
if ! aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  warn "State bucket '$STATE_BUCKET' not accessible — Terraform may not find remote state."
fi

if ! terraform init -reconfigure 2>/dev/null; then
  warn "terraform init failed — trying with -upgrade..."
  terraform init -upgrade -reconfigure
fi

terraform destroy -auto-approve

ok "All Terraform-managed resources destroyed."

# ─── Step 6: Verify no leftover EC2 instances ─────────────────────────────────
section "Step 6 — Checking for leftover EC2 instances"

LEFTOVER_IDS=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters \
    "Name=tag:aws:eks:cluster-name,Values=${CLUSTER_NAME}" \
    "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text 2>/dev/null || true)

if [[ -n "$LEFTOVER_IDS" && "$LEFTOVER_IDS" != "None" ]]; then
  warn "Leftover EC2 instances detected: $LEFTOVER_IDS"
  if confirm "Terminate these instances now?"; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $LEFTOVER_IDS --region "$AWS_REGION"
    log "Waiting for instance termination..."
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $LEFTOVER_IDS --region "$AWS_REGION"
    ok "Instances terminated."

    warn "Re-running terraform destroy to clean up any stuck resources..."
    terraform destroy -auto-approve
    ok "Final terraform destroy complete."
  else
    warn "Instances left running. Subnet/VPC deletion may fail — terminate them manually then re-run terraform destroy."
  fi
else
  ok "No leftover EC2 instances."
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
section "Cleanup complete"

cat <<EOF

  All Terraform-managed resources for cluster '$CLUSTER_NAME' have been removed.

  The following resources are NOT managed by Terraform and were NOT deleted:

    S3 state bucket:  s3://${STATE_BUCKET}
    KMS keys:         (if any — check the AWS Console under KMS)

  To delete the state bucket manually (only if you no longer need state history):
    aws s3 rm s3://${STATE_BUCKET} --recursive
    aws s3api delete-bucket --bucket ${STATE_BUCKET} --region ${AWS_REGION}

  To schedule KMS key deletion (minimum 7-day waiting period):
    aws kms list-keys --region ${AWS_REGION}
    aws kms schedule-key-deletion --key-id <key-id> --pending-window-in-days 7 --region ${AWS_REGION}

EOF

ok "Done."
