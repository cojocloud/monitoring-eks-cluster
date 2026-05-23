# EKS Observability Stack: Prometheus & Grafana with Terraform and Helm

A production-ready observability platform deployed on Amazon EKS using Terraform. This project provisions an EKS cluster, installs the full Prometheus + Grafana monitoring stack via Helm, configures Route53 DNS, and deploys a sample microservices application to observe.

Live stack: [prometheus.cojocloudsolutions.com](http://prometheus.cojocloudsolutions.com) | [grafana.cojocloudsolutions.com](http://grafana.cojocloudsolutions.com)

---

## What is Observability on EKS?

Observability in Kubernetes goes beyond traditional monitoring. It answers not just *"Is my system working?"* but *"Why is it not working?"*

The three pillars:
- **Metrics** — quantitative data over time (CPU, memory, request counts)
- **Logs** — textual event records (pod logs, system events)
- **Traces** — request paths across microservices (distributed tracing)

This project covers the **metrics** pillar end-to-end with Prometheus and Grafana.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AWS Cloud (us-east-1)                      │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    EKS Cluster (1.32)                       │   │
│  │                                                             │   │
│  │  ┌─────────────────┐    ┌─────────────────┐                 │   │
│  │  │   Prometheus    │◄───┤  Node Exporter  │                 │   │
│  │  │     Server      │    │  (per node)     │                 │   │
│  │  │  - Scrapes      │    └─────────────────┘                 │   │
│  │  │  - Stores 30d   │                                        │   │
│  │  │  - Alert rules  │    ┌─────────────────┐                 │   │
│  │  └────────┬────────┘◄───┤ kube-state-     │                 │   │
│  │           │             │ metrics         │                 │   │
│  │           ▼             └─────────────────┘                 │   │
│  │  ┌─────────────────┐                                        │   │
│  │  │    Grafana      │    ┌─────────────────┐                 │   │
│  │  │  - Dashboards   │◄───┤  AlertManager   │                 │   │
│  │  │  - Persistence  │    │  - CrashLoop    │                 │   │
│  │  └─────────────────┘    │  - HighCPU      │                 │   │
│  │                         │  - NodeNotReady │                 │   │
│  │  ┌─────────────────┐    └─────────────────┘                 │   │
│  │  │  NGINX Ingress  │──► Route53 DNS → NLB                   │   │
│  │  │  (NLB-backed)   │                                        │   │
│  │  └─────────────────┘                                        │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  S3 (Terraform state) │ VPC │ Private + Public Subnets │ NAT GW    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Stack

| Component | Tool | Version |
|---|---|---|
| Infrastructure as Code | Terraform | >= 1.0 |
| Kubernetes | Amazon EKS | 1.32 |
| Metrics collection | Prometheus (kube-prometheus-stack) | chart 67.9.0 |
| Visualization | Grafana | bundled with above |
| Alerting | AlertManager | bundled with above |
| Ingress | NGINX Ingress Controller | 4.8.3 |
| DNS | AWS Route53 | — |
| Sample app | Voting App (microservices) | — |

---

## What I Improved Over a Standard Setup

This project goes beyond a basic Prometheus/Grafana install:

1. **Sensitive variable for Grafana password** — no hardcoded credentials anywhere in the codebase; the password is passed as a `sensitive` Terraform variable and never emitted in plaintext outputs.
2. **Grafana persistence** — dashboards survive pod restarts via an EBS-backed PVC (10Gi, `gp2`). The common mistake of leaving `persistence.enabled = false` means losing all custom dashboards on every restart.
3. **Custom AlertManager rules** — three alert groups out of the box: `PodCrashLooping`, `PodNotReady`, `NodeNotReady`, `HighCPUUsage`, `HighMemoryUsage`. Most tutorials skip this, but it's why you set up alerting in the first place.
4. **NGINX metrics scraped by Prometheus** — `serviceMonitor.enabled = true` means NGINX request/error/latency metrics flow into Prometheus and are visible in Grafana dashboards.
5. **API endpoint CIDR restriction** — `cluster_endpoint_public_access_cidrs` variable lets you lock down who can reach the EKS API server instead of leaving it open to `0.0.0.0/0`.
6. **`domain_name` variable** — the domain is no longer scattered across files as a hardcoded string; all DNS records and ingress hosts reference `var.domain_name`.
7. **`terraform.tfvars.example`** — a committed example file documents every personal value so anyone cloning the repo knows exactly what to configure.

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0
- kubectl
- Helm >= 3.0
- A Route53 hosted zone for your domain
- An S3 bucket for Terraform state (update `providers.tf`)

---

## Deployment

### 1. Configure your variables

```bash
cd infrastructure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your domain, cluster name, and Grafana password
```

### 2. Add Helm repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### 3. Deploy infrastructure

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
- Create a VPC with public/private subnets across 2 AZs
- Provision an EKS 1.32 cluster with managed node groups (`t3.medium`, 2 nodes)
- Install NGINX Ingress Controller (NLB-backed)
- Install the kube-prometheus-stack (Prometheus + Grafana + AlertManager)
- Configure custom alert rules

### 4. Point your domain at the NLB

DNS is managed at your domain registrar — Terraform does not create DNS records. After `terraform apply`, get the NLB hostname:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Add four CNAME records at your registrar pointing at that hostname:

| Name | Type | Value |
|------|------|-------|
| `prometheus` | CNAME | `<nlb-hostname>` |
| `grafana` | CNAME | `<nlb-hostname>` |
| `vote` | CNAME | `<nlb-hostname>` |
| `result` | CNAME | `<nlb-hostname>` |

Verify DNS propagation:
```bash
dig prometheus.yourdomain.com +short
```

### 5. Deploy the sample voting app

```bash
cd example-voting-app/k8s-specifications
kubectl apply -f .
# Run twice — the namespace is created on the first pass
kubectl apply -f .
```

---

## Accessing the Stack

| Service | URL |
|---|---|
| Prometheus | http://prometheus.cojocloudsolutions.com |
| Grafana | http://grafana.cojocloudsolutions.com |
| Vote app | http://vote.cojocloudsolutions.com |
| Results app | http://result.cojocloudsolutions.com |

**Grafana login:** username `admin`, password set in `terraform.tfvars`.

Or via port-forward (no DNS required):
```bash
# Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

---

## Validation

### Check Prometheus targets
Go to **Status → Targets** — all targets should show `UP`.

### Sample PromQL queries

```promql
# CPU usage by node
100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Pod count by namespace
count by (namespace) (kube_pod_info)

# NGINX request rate (requires serviceMonitor)
rate(nginx_ingress_controller_requests[5m])
```

### Recommended Grafana dashboards to import

| Dashboard | ID |
|---|---|
| Kubernetes / Compute Resources / Cluster | 315 |
| Kubernetes / Compute Resources / Namespace | 3146 |
| Kubernetes / Compute Resources / Pod | 7633 |
| Node Exporter Full | 1860 |
| NGINX Ingress Controller | 9614 |
| ETCD Metrics | 3070 |

---

## Outcomes

### Kubernetes API Server — 100% Availability
![Kubernetes API Server dashboard showing 100% availability and SLI metrics](images/image1.png)

### Cluster Compute Resources — CPU & Memory by Namespace
![Cluster compute resources dashboard showing 4.55% CPU utilisation and 35.4% memory usage across vote, monitoring, ingress-nginx and kube-system namespaces](images/image2.png)

### Persistent Volumes — Grafana PVC
![Persistent volumes dashboard showing Grafana PVC with 30.9 MiB used out of 10 GiB (0.310%)](images/image3.png)

### Multi-Cluster Compute Resources Overview
![Multi-cluster compute resources dashboard showing cluster-wide CPU and memory utilisation](images/image4.png)

### Prometheus — Live PromQL Queries
![Prometheus query UI showing live PromQL queries for node CPU usage, memory usage, and pod count by namespace](images/image5.png)

---

## Cleanup

```bash
# 1. Remove the voting app
kubectl delete namespace vote

# 2. Delete the NLB created by the nginx ingress controller
#    (Terraform cannot delete it — it was created by Kubernetes)
NLB_ARN=$(aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)
aws elbv2 delete-load-balancer --load-balancer-arn $NLB_ARN --region us-east-1

# Wait for the NLB to be fully deleted before continuing
until [ $(aws elbv2 describe-load-balancers --region us-east-1 \
  --query "length(LoadBalancers)" --output text) -eq 0 ]; do sleep 10; done

# 3. Destroy all Terraform-managed infrastructure
cd infrastructure
terraform destroy
```

> **If `terraform destroy` fails on VPC/subnet deletion:** EC2 node instances may still be running. Find and terminate them:
> ```bash
> aws ec2 describe-instances --filters "Name=tag:aws:eks:cluster-name,Values=<cluster-name>" \
>   --query "Reservations[*].Instances[*].InstanceId" --output text
> aws ec2 terminate-instances --instance-ids <id1> <id2>
> ```
> Then re-run `terraform destroy`.

> **Note:** The S3 state bucket and any KMS keys are not destroyed by Terraform. Delete them manually if no longer needed. KMS keys have a minimum 7-day deletion waiting period.

---

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [kube-prometheus-stack Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Amazon EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Kubernetes Monitoring Best Practices](https://kubernetes.io/docs/concepts/cluster-administration/monitoring/)
