# Deployment Guide

Step-by-step instructions to deploy the EKS observability stack from scratch.

---

## Prerequisites

Install the following tools before starting:

| Tool | Min Version | Install |
|---|---|---|
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | >= 1.0 | https://developer.hashicorp.com/terraform/install |
| kubectl | >= 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | >= 3.0 | https://helm.sh/docs/intro/install/ |

Verify everything is installed:

```bash
aws --version
terraform --version
kubectl version --client
helm version
```

---

## Step 1 — Configure AWS credentials

```bash
aws configure
```

Enter your AWS Access Key ID, Secret Access Key, default region (`us-east-1`), and output format (`json`).

Confirm it works:

```bash
aws sts get-caller-identity
```

You should see your AWS account ID and user/role ARN.

---

## Step 2 — Create the S3 bucket for Terraform state

This bucket must exist before running `terraform init`. Create it once:

```bash
aws s3api create-bucket \
  --bucket cojocloud-terraform-state-bucket \
  --region us-east-1

# Enable versioning so you can recover previous state files
aws s3api put-bucket-versioning \
  --bucket cojocloud-terraform-state-bucket \
  --versioning-configuration Status=Enabled

# Enable encryption at rest
aws s3api put-bucket-encryption \
  --bucket cojocloud-terraform-state-bucket \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'
```

---

## Step 3 — Set up your Route53 hosted zone

You need a public hosted zone for `cojocloudsolutions.com` in Route53.

If it doesn't exist yet:
```bash
aws route53 create-hosted-zone \
  --name cojocloudsolutions.com \
  --caller-reference $(date +%s)
```

If it already exists, confirm it:
```bash
aws route53 list-hosted-zones-by-name --dns-name cojocloudsolutions.com
```

Make sure your domain registrar's nameservers point to the Route53 NS records for this zone.

---

## Step 4 — Configure your Terraform variables

```bash
cd infrastructure
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in your values:

```hcl
aws_region   = "us-east-1"
cluster_name = "CojoCloud-EKS-Cluster"
environment  = "DEV"
domain_name  = "cojocloudsolutions.com"

# Restrict to your own IP for security — find it with: curl ifconfig.me
cluster_endpoint_public_access_cidrs = ["YOUR_IP/32"]

# Strong password for Grafana admin login
grafana_admin_password = "YourStrongPassword123!"
```

> `terraform.tfvars` is gitignored — it will never be committed.

---

## Step 5 — Add Helm repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

---

## Step 6 — Initialize Terraform

```bash
cd infrastructure   # if not already there
terraform init
```

Expected output: `Terraform has been successfully initialized!`

---

## Step 7 — Review the plan

```bash
terraform plan
```

Review the resources Terraform will create:
- 1 VPC with public/private subnets
- 1 EKS cluster (1.32) with a managed node group (2x `t3.medium`)
- NGINX Ingress Controller (NLB-backed)
- Route53 A records for Prometheus and Grafana
- kube-prometheus-stack (Prometheus + Grafana + AlertManager)

---

## Step 8 — Apply

```bash
terraform apply
```

Type `yes` when prompted. This takes approximately **15–20 minutes** — EKS cluster creation is the longest step.

When complete, you will see output with:
- `cluster_endpoint`
- `cluster_name`
- `monitoring_access_commands`

---

## Step 9 — Update your kubeconfig

Terraform runs this automatically via a `null_resource`, but run it manually to confirm:

```bash
aws eks --region us-east-1 update-kubeconfig --name CojoCloud-EKS-Cluster
```

Verify cluster access:

```bash
kubectl get nodes
```

You should see 2 nodes in `Ready` state.

---

## Step 10 — Verify the monitoring stack

Check all monitoring pods are running:

```bash
kubectl get pods -n monitoring
```

All pods should be `Running` or `Completed`. This may take 2–3 minutes after `terraform apply` finishes.

Check the ingress records:

```bash
kubectl get ingress -n monitoring
```

You should see ingress entries for both Prometheus and Grafana with the NLB hostname assigned.

Check the NLB hostname assigned to NGINX:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

## Step 11 — Access Prometheus and Grafana

Once DNS propagates (usually 1–5 minutes after `terraform apply`):

| Service | URL |
|---|---|
| Prometheus | https://prometheus.cojocloudsolutions.com |
| Grafana | https://grafana.cojocloudsolutions.com |

**Grafana login:** username `admin`, password is whatever you set in `terraform.tfvars`.

If DNS hasn't propagated yet, use port-forward:

```bash
# Prometheus (opens at http://localhost:9090)
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Grafana (opens at http://localhost:3000)
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

---

## Step 12 — Import Grafana dashboards

In Grafana, go to **Dashboards → Import** and use these dashboard IDs:

| Dashboard | ID |
|---|---|
| Kubernetes / Compute Resources / Cluster | 315 |
| Kubernetes / Compute Resources / Namespace | 3146 |
| Kubernetes / Compute Resources / Pod | 7633 |
| Node Exporter Full | 1860 |
| NGINX Ingress Controller | 9614 |

Set the data source to **Prometheus** when importing each one.

---

## Step 13 — Deploy the sample voting app (optional)

```bash
cd example-voting-app/k8s-specifications
kubectl apply -f .
```

Verify the pods are running:

```bash
kubectl get pods
kubectl get svc
```

The voting app services will appear in Prometheus and on the Grafana dashboards.

---

## Troubleshooting

**Pods stuck in `Pending`**
```bash
kubectl describe pod <pod-name> -n monitoring
```
Usually a node resource issue — check `kubectl get nodes` and `kubectl describe node`.

**Ingress has no address**
```bash
kubectl get svc -n ingress-nginx
```
The NLB can take 2–3 minutes to be provisioned by AWS after the Helm release completes.

**Prometheus targets showing `DOWN`**
Go to Status → Targets in the Prometheus UI. Click the endpoint to see the error. Usually a network policy or scrape config issue.

**`terraform apply` fails on Helm release**
The EKS cluster may not be fully ready. Run `terraform apply` again — it will pick up where it left off.

**Can't reach Prometheus/Grafana via domain**
```bash
# Check if the Route53 record was created
aws route53 list-resource-record-sets \
  --hosted-zone-id $(aws route53 list-hosted-zones-by-name \
    --dns-name cojocloudsolutions.com \
    --query 'HostedZones[0].Id' --output text | cut -d'/' -f3)
```

---

## Cleanup

Remove the voting app:
```bash
cd example-voting-app/k8s-specifications
kubectl delete -f .
```

Destroy all AWS infrastructure (stops billing):
```bash
cd infrastructure
terraform destroy
```

Type `yes` when prompted. This takes approximately 10–15 minutes.

> The S3 state bucket is not managed by Terraform and will not be deleted by `terraform destroy`. Delete it manually if you no longer need it.
