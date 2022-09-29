resource "kubernetes_namespace" "work-namespace" {
  metadata {
    annotations = {
      name = "ii-annotation"
    }

    labels = {
      cert-manager-tls = "sync"
    }

    name = var.namespace
  }
}
