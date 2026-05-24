#!/usr/bin/env bash
# End-to-end deployment: EKS cluster + monitoring stack + voting app
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/infrastructure"
VOTING_APP_DIR="$SCRIPT_DIR/example-voting-app/k8s-specifications"
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

# ─── Step 1: Prerequisites ────────────────────────────────────────────────────
section "Step 1 — Checking prerequisites"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found ($(command -v "$1"))"
  else
    die "$1 is not installed. See DEPLOYMENT.md for install links."
  fi
}

check_cmd aws
check_cmd terraform
check_cmd kubectl
check_cmd helm

# ─── Step 2: AWS credentials ──────────────────────────────────────────────────
section "Step 2 — Validating AWS credentials"

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || die "AWS credentials not configured. Run: aws configure"

ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
USER_ARN=$(echo  "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*"'     | cut -d'"' -f4)
ok "Account: $ACCOUNT_ID"
ok "Identity: $USER_ARN"

AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
log "Region: $AWS_REGION"

# ─── Step 3: Terraform state S3 bucket ───────────────────────────────────────
section "Step 3 — Terraform state S3 bucket"

if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  ok "Bucket '$STATE_BUCKET' already exists."
else
  log "Creating S3 bucket '$STATE_BUCKET' in $AWS_REGION..."

  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$STATE_BUCKET" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$STATE_BUCKET" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi

  aws s3api put-bucket-versioning \
    --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
      }]
    }'

  ok "Bucket '$STATE_BUCKET' created with versioning and encryption."
fi

# ─── Step 4: terraform.tfvars ─────────────────────────────────────────────────
section "Step 4 — Terraform variables"

TFVARS="$INFRA_DIR/terraform.tfvars"

if [[ -f "$TFVARS" ]]; then
  ok "terraform.tfvars already exists."
  # Warn if the password placeholder is still there
  if grep -q "CHANGE_ME" "$TFVARS" 2>/dev/null; then
    die "terraform.tfvars still contains 'CHANGE_ME'. Set a real grafana_admin_password before continuing."
  fi
else
  warn "terraform.tfvars not found. Creating from example..."
  cp "$INFRA_DIR/terraform.tfvars.example" "$TFVARS"

  # Prompt for the minimum required values
  echo ""
  read -rp "$(echo -e "  Grafana admin password: ")" GRAFANA_PASS
  [[ -z "$GRAFANA_PASS" ]] && die "Grafana password cannot be empty."

  read -rp "$(echo -e "  Your public IP (leave blank for 0.0.0.0/0): ")" MY_IP
  if [[ -n "$MY_IP" ]]; then
    CIDR_VALUE="[\"${MY_IP}/32\"]"
  else
    warn "No IP restriction set. The EKS API endpoint will be publicly accessible."
    CIDR_VALUE='["0.0.0.0/0"]'
  fi

  # Write the values — using temp file for portability (no sed -i differences between macOS/Linux)
  TMPFILE=$(mktemp)
  while IFS= read -r line; do
    if [[ "$line" =~ ^grafana_admin_password ]]; then
      echo "grafana_admin_password = \"$GRAFANA_PASS\""
    elif [[ "$line" =~ ^cluster_endpoint_public_access_cidrs ]]; then
      echo "cluster_endpoint_public_access_cidrs = $CIDR_VALUE"
    else
      echo "$line"
    fi
  done < "$TFVARS" > "$TMPFILE"
  mv "$TMPFILE" "$TFVARS"
  ok "terraform.tfvars written."
fi

# Read cluster_name and region from tfvars for later use
CLUSTER_NAME=$(grep 'cluster_name' "$TFVARS" | cut -d'"' -f2 || echo "CojoCloud-EKS-Cluster")
DOMAIN_NAME=$(grep  'domain_name'  "$TFVARS" | cut -d'"' -f2 || echo "cojocloudsolutions.com")
log "Cluster name: $CLUSTER_NAME"
log "Domain name:  $DOMAIN_NAME"

# ─── Step 5: Helm repositories ───────────────────────────────────────────────
section "Step 5 — Helm repositories"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana              https://grafana.github.io/helm-charts               2>/dev/null || true
helm repo add ingress-nginx        https://kubernetes.github.io/ingress-nginx           2>/dev/null || true
helm repo update
ok "Helm repos updated."

# ─── Step 6: Terraform init ───────────────────────────────────────────────────
section "Step 6 — Terraform init"

cd "$INFRA_DIR"
terraform init -upgrade
ok "Terraform initialized."

# ─── Step 7: Terraform plan ───────────────────────────────────────────────────
section "Step 7 — Terraform plan"

PLAN_FILE="/tmp/eks-deploy.tfplan"
terraform plan -out="$PLAN_FILE"
echo ""
warn "Review the plan above before applying."
confirm "Apply the plan and provision all infrastructure?" || die "Aborted by user."

# ─── Step 8: Terraform apply ──────────────────────────────────────────────────
section "Step 8 — Terraform apply  (~15-20 min)"

terraform apply "$PLAN_FILE"
ok "Infrastructure provisioned."

# ─── Step 9: kubeconfig ───────────────────────────────────────────────────────
section "Step 9 — Updating kubeconfig"

aws eks --region "$AWS_REGION" update-kubeconfig --name "$CLUSTER_NAME"
ok "kubeconfig updated."

# ─── Step 10: Wait for nodes ──────────────────────────────────────────────────
section "Step 10 — Waiting for nodes to be Ready"

log "Waiting for all nodes (up to 5 minutes)..."
kubectl wait node --all --for=condition=Ready --timeout=300s
ok "All nodes are Ready."
kubectl get nodes -o wide

# ─── Step 11: Verify monitoring stack ────────────────────────────────────────
section "Step 11 — Verifying monitoring stack"

log "Waiting for monitoring pods (up to 5 minutes)..."
kubectl wait pod --all -n monitoring \
  --for=condition=Ready --timeout=300s 2>/dev/null || true

echo ""
kubectl get pods -n monitoring
echo ""
kubectl get ingress -n monitoring

NLB_HOST=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
ok "NLB hostname: ${NLB_HOST:-<pending — wait 2-3 min for AWS to provision>}"

# ─── Step 12: Voting app (optional) ──────────────────────────────────────────
section "Step 12 — Example voting app (optional)"

if confirm "Deploy the example voting app?"; then
  cd "$VOTING_APP_DIR"
  # Applied twice: first pass creates the namespace, second deploys resources
  kubectl apply -f . || true
  kubectl apply -f .
  cd "$INFRA_DIR"
  log "Waiting for voting app pods (up to 3 minutes)..."
  kubectl wait pod --all -n vote --for=condition=Ready --timeout=180s 2>/dev/null || true
  echo ""
  kubectl get pods -n vote
  kubectl get ingress -n vote
  ok "Voting app deployed."
else
  log "Skipped."
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
section "Deployment complete"

cat <<EOF

  Cluster:    $CLUSTER_NAME
  Region:     $AWS_REGION
  NLB:        ${NLB_HOST}

  Services (requires DNS CNAMEs pointing at the NLB above):
    Prometheus  →  http://prometheus.${DOMAIN_NAME}
    Grafana     →  http://grafana.${DOMAIN_NAME}
    Vote        →  http://vote.${DOMAIN_NAME}
    Result      →  http://result.${DOMAIN_NAME}

  Port-forward (no DNS needed):
    kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
    kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

  Grafana login: admin / <your grafana_admin_password from terraform.tfvars>

  DNS — add CNAME records at your registrar pointing to the NLB hostname:
    prometheus.${DOMAIN_NAME}  →  ${NLB_HOST}
    grafana.${DOMAIN_NAME}     →  ${NLB_HOST}
    vote.${DOMAIN_NAME}        →  ${NLB_HOST}
    result.${DOMAIN_NAME}      →  ${NLB_HOST}

  Grafana dashboard IDs to import (Dashboards → Import, data source = Prometheus):
    315   Kubernetes / Compute Resources / Cluster
    3146  Kubernetes / Compute Resources / Namespace
    7633  Kubernetes / Compute Resources / Pod
    1860  Node Exporter Full
    9614  NGINX Ingress Controller

EOF

ok "Run ./cleanup.sh when you are done to tear everything down."
