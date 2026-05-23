################################################################################
# Create ingress-nginx namespace
################################################################################
resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      name = "ingress-nginx"
    }
  }
  depends_on = [module.eks]
}

################################################################################
# Install NGINX Ingress Controller using Helm
################################################################################
resource "helm_release" "nginx_ingress" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  version    = "4.8.3"

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"                              = "nlb"
            "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
          }
        }
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = false # managed separately below after Prometheus CRDs are installed
          }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.ingress_nginx]
}

################################################################################
# Get the NLB hostname from nginx ingress controller
################################################################################
data "kubernetes_service" "nginx_ingress_controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = kubernetes_namespace.ingress_nginx.metadata[0].name
  }
  depends_on = [helm_release.nginx_ingress]
}

################################################################################
# ServiceMonitor for NGINX — applied via kubectl after Prometheus CRDs exist.
# kubernetes_manifest validates CRDs at plan time so it cannot be used here.
################################################################################
resource "null_resource" "nginx_service_monitor" {
  triggers = {
    prometheus_release = helm_release.prometheus.id
    nginx_release      = helm_release.nginx_ingress.id
  }

  provisioner "local-exec" {
    command = <<-EOF
      kubectl apply -f - <<YAML
      apiVersion: monitoring.coreos.com/v1
      kind: ServiceMonitor
      metadata:
        name: ingress-nginx-controller
        namespace: ${kubernetes_namespace.monitoring.metadata[0].name}
        labels:
          release: prometheus
      spec:
        namespaceSelector:
          matchNames:
            - ${kubernetes_namespace.ingress_nginx.metadata[0].name}
        selector:
          matchLabels:
            app.kubernetes.io/name: ingress-nginx
            app.kubernetes.io/component: controller
        endpoints:
          - port: metrics
            interval: 30s
      YAML
    EOF
  }

  depends_on = [helm_release.nginx_ingress, helm_release.prometheus]
}
