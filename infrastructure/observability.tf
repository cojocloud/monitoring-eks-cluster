
################################################################################
# StorageClass backed by the EBS CSI driver
################################################################################
resource "kubernetes_storage_class_v1" "gp2_csi" {
  metadata {
    name = "gp2-csi"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp2"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

################################################################################
# Create monitoring namespace
################################################################################
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      name = "monitoring"
    }
  }
  depends_on = [module.eks]
}

################################################################################
# Install Prometheus stack using Helm
################################################################################
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "67.9.0"

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          retention = "30d"
        }
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts            = ["prometheus.${var.domain_name}"]
          paths            = ["/"]
          annotations = {
            "nginx.ingress.kubernetes.io/rewrite-target" = "/"
          }
        }
      }

      grafana = {
        enabled       = true
        adminPassword = var.grafana_admin_password
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts            = ["grafana.${var.domain_name}"]
          path             = "/"
          annotations = {
            "nginx.ingress.kubernetes.io/rewrite-target" = "/"
          }
        }
        persistence = {
          enabled          = true
          storageClassName = "gp2-csi"
          size             = "10Gi"
        }
      }

      alertmanager = {
        enabled = true
      }

      # Custom alert rules for production awareness
      additionalPrometheusRulesMap = {
        cojocloud-alerts = {
          groups = [
            {
              name = "pod-health"
              rules = [
                {
                  alert = "PodCrashLooping"
                  expr  = "rate(kube_pod_container_status_restarts_total[5m]) * 60 * 5 > 0"
                  for   = "5m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "Pod {{ $labels.pod }} is crash looping"
                    description = "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been restarting frequently in the last 5 minutes."
                  }
                },
                {
                  alert = "PodNotReady"
                  expr  = "kube_pod_status_ready{condition=\"true\"} == 0"
                  for   = "10m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "Pod {{ $labels.pod }} not ready"
                    description = "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been in a non-ready state for more than 10 minutes."
                  }
                }
              ]
            },
            {
              name = "node-health"
              rules = [
                {
                  alert = "NodeNotReady"
                  expr  = "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
                  for   = "1m"
                  labels = {
                    severity = "critical"
                  }
                  annotations = {
                    summary     = "Node {{ $labels.node }} is not ready"
                    description = "Node {{ $labels.node }} has been not ready for more than 1 minute."
                  }
                },
                {
                  alert = "HighCPUUsage"
                  expr  = "100 - (avg by(instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 80"
                  for   = "10m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "High CPU usage on {{ $labels.instance }}"
                    description = "Node {{ $labels.instance }} CPU usage has been above 80% for more than 10 minutes."
                  }
                },
                {
                  alert = "HighMemoryUsage"
                  expr  = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85"
                  for   = "10m"
                  labels = {
                    severity = "warning"
                  }
                  annotations = {
                    summary     = "High memory usage on {{ $labels.instance }}"
                    description = "Node {{ $labels.instance }} memory usage has been above 85% for more than 10 minutes."
                  }
                }
              ]
            }
          ]
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring, helm_release.nginx_ingress, kubernetes_storage_class_v1.gp2_csi]
}
