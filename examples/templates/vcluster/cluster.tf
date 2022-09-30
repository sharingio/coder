terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.4.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.12.1"
    }
  }
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<EOT
    #!/bin/bash

    # home folder can be empty, so copying default bash settings
    if [ ! -f ~/.profile ]; then
      cp /etc/skel/.profile $HOME
    fi
    if [ ! -f ~/.bashrc ]; then
      cp /etc/skel/.bashrc $HOME
    fi

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh  | tee code-server-install.log
    code-server --auth none --port 13337 | tee code-server-install.log &
  EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id      = coder_agent.main.id
  name          = "code-server"
  icon          = "/icon/code.svg"
  url           = "http://localhost:13337?folder=/home/coder"
  relative_path = true

  healthcheck {
    url       = "http://localhost:1337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "kubernetes_namespace" "workspace" {
  metadata {
    name = data.coder_workspace.me.name
    labels = {
      cert-manager-tls = "sync"
    }
  }
}

resource "kubernetes_manifest" "cluster" {
  manifest = {
    "apiVersion" = "cluster.x-k8s.io/v1beta1"
    "kind"       = "Cluster"
    "metadata" = {
      "name"      = data.coder_workspace.me.name
      "namespace" = data.coder_workspace.me.name
    }
    "spec" = {
      "controlPlaneRef" = {
        "apiVersion" = "infrastructure.cluster.x-k8s.io/v1alpha1"
        "kind"       = "VCluster"
        "name"       = data.coder_workspace.me.name
      }
      "infrastructureRef" = {
        "apiVersion" = "infrastructure.cluster.x-k8s.io/v1alpha1"
        "kind"       = "VCluster"
        "name"       = data.coder_workspace.me.name
      }
    }
  }
}

resource "kubernetes_manifest" "vcluster" {
  provisioner "local-exec" {
    command = "kubectl wait --for=condition=Ready --timeout=999s -n ${data.coder_workspace.me.name} cluster ${data.coder_workspace.me.name}"
  }
  provisioner "local-exec" {
    command = "kubectl get secrets -n ${data.coder_workspace.me.name} ${data.coder_workspace.me.name}-kubeconfig -o jsonpath={.data.value} | base64 -d > kubeconfig"
  }
  manifest = {
    "apiVersion" = "infrastructure.cluster.x-k8s.io/v1alpha1"
    "kind"       = "VCluster"
    "metadata" = {
      "name"      = data.coder_workspace.me.name
      "namespace" = data.coder_workspace.me.name
    }
    "spec" = {
      "controlPlaneEndpoint" = {
        "host" = ""
        "port" = 0
      }
      "kubernetesVersion" = "1.23.4"
      "helmRelease" = {
        "chart" = {
          "name"    = null
          "repo"    = null
          "version" = null
        }
        "values" = <<-EOT
        service:
          type: NodePort
        syncer:
          extraArgs:
            - --tls-san="${data.coder_workspace.me.name}.sanskar.pair.shairng.io"
        EOT
      }
    }
  }
}

resource "kubernetes_manifest" "ingress_clusters" {
  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "Ingress"
    "metadata" = {
      "annotations" = {
        "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
        "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
      }
      "name"      = data.coder_workspace.me.name
      "namespace" = data.coder_workspace.me.name
    }
    "spec" = {
      "ingressClassName" = "contour-external"
      "rules" = [
        {
          "host" = "${data.coder_workspace.me.name}.sanskar.pair.sharing.io"
          "http" = {
            "paths" = [
              {
                "backend" = {
                  "service" = {
                    "name" = data.coder_workspace.me.name
                    "port" = {
                      "number" = 443
                    }
                  }
                }
                "path"     = "/"
                "pathType" = "ImplementationSpecific"
              },
            ]
          }
        },
      ]
      "tls" = [
        {
          "hosts" = [
            "${data.coder_workspace.me.name}.sanskar.pair.sharing.io",
          ]
        },
      ]
    }
  }
}
# This is generated from the vcluster...
# Need to find a way for it to wait before running, so that the secret exists
# data "kubernetes_resource" "kubeconfig" {
#   api_version = "v1"
#   kind        = "Secret"
#   depends_on = [
#     kubernetes_manifest.vcluster
#   ]
#   metadata {
#     name      = "vcluster-kubeconfig"
#     namespace = var.namespace
#   }
# }

# We'll need to use the kubeconfig from above to provision the coder/pair environment
