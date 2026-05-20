# EKS Observability Stack: Prometheus & Grafana with Terraform and Helm

A production-ready observability platform deployed on Amazon EKS using Terraform. This project provisions an EKS cluster, installs the full Prometheus + Grafana monitoring stack via Helm, configures Route53 DNS, and deploys a sample microservices application to observe.

Live stack: [prometheus.cojocloudsolutions.com](https://prometheus.cojocloudsolutions.com) | [grafana.cojocloudsolutions.com](https://grafana.cojocloudsolutions.com)

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
│                         AWS Cloud (us-east-1)                       │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    EKS Cluster (1.32)                        │   │
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
│                                                                     │
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
- Create Route53 A records pointing your domain at the NLB
- Install the kube-prometheus-stack (Prometheus + Grafana + AlertManager)
- Configure custom alert rules

### 4. Deploy the sample voting app

```bash
cd example-voting-app/k8s-specifications
kubectl apply -f .
```

---

## Accessing the Stack

| Service | URL |
|---|---|
| Prometheus | https://prometheus.cojocloudsolutions.com |
| Grafana | https://grafana.cojocloudsolutions.com |

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

![Prometheus targets](/images/prom_1.png)

![Prometheus queries](/images/prom_2.png)

![Grafana cluster dashboard](/images/graf_1.png)

![Grafana node dashboard](/images/graf_2.png)

---

## Cleanup

```bash
# Remove the voting app
cd example-voting-app/k8s-specifications
kubectl delete -f .

# Destroy all AWS infrastructure
cd infrastructure
terraform destroy
```

---

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [kube-prometheus-stack Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Amazon EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Kubernetes Monitoring Best Practices](https://kubernetes.io/docs/concepts/cluster-administration/monitoring/)
