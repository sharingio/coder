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

# https://www.terraform.io/language/providers/configuration#provider-configuration-1
# > You can use expressions in the values of these configuration arguments,
# but can only reference values that are known before the configuration is applied.
# This means you can safely reference input variables, but not attributes
# exported by resources (with an exception for resource arguments that
# are specified directly in the configuration).
#### no data.X :(
# provider "kubernetes" {
#   alias                  = "vcluster"
#   host                   = yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["clusters"][0]["cluster"]["server"]
#   client_certificate     = base64decode(yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["users"][0]["user"]["client-certificate-data"])
#   client_key             = base64decode(yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["users"][0]["user"]["client-key-data"])
#   cluster_ca_certificate = base64decode(yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["clusters"][0]["cluster"]["certificate-authority-data"])
# }

variable "base_domain" {
  type    = string
  default = "sanskar.pair.sharing.io"
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
  # This local-exec ensures cluster is available before the resource is considered ready
  provisioner "local-exec" {
    command = "kubectl wait --for=condition=Ready --timeout=999s -n ${data.coder_workspace.me.name} cluster ${data.coder_workspace.me.name}"
  }
  manifest = {
    "apiVersion" = "cluster.x-k8s.io/v1beta1"
    "kind"       = "Cluster"
    "metadata" = {
      "name"      = data.coder_workspace.me.name
      "namespace" = data.coder_workspace.me.name
      "labels" = {
        "cluster-name" = data.coder_workspace.me.name
      }
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
            - --tls-san="${data.coder_workspace.me.name}.${var.base_domain}"
            - --tls-san="${data.coder_workspace.me.name}.${data.coder_workspace.me.name}.svc"
        EOT
      }
    }
  }
}

resource "kubernetes_manifest" "configmap_capi_init" {
  manifest = {
    "kind" = "ConfigMap"
    "metadata" = {
      "name"      = "capi-init"
      "namespace" = data.coder_workspace.me.name
    }
    "apiVersion" = "v1"
    "data" = {
      "cool.yaml" = templatefile("cool.template.yaml",
        {
          coder_command = jsonencode(["sh", "-c", coder_agent.main.init_script]),
          coder_token   = coder_agent.main.token
      })
    }
  }
}

resource "kubernetes_manifest" "clusterresourceset_capi_init" {
  manifest = {
    "apiVersion" = "addons.cluster.x-k8s.io/v1beta1"
    "kind"       = "ClusterResourceSet"
    "metadata" = {
      "name"      = data.coder_workspace.me.name
      "namespace" = data.coder_workspace.me.name
    }
    "spec" = {
      "clusterSelector" = {
        "matchLabels" = {
          "cluster-name" = data.coder_workspace.me.name
        }
      }
      "resources" = [
        {
          "kind" = "ConfigMap"
          "name" = "capi-init"
        },
      ]
      "strategy" = "ApplyOnce"
    }
  }
}
# data "kubernetes_resource" "cluster-kubeconfig" {
#   api_version = "v1"
#   kind        = "Secret"
#   metadata {
#     name      = "${data.coder_workspace.me.name}-kubeconfig"
#     namespace = data.coder_workspace.me.name
#   }

#   depends_on = [
#     kubernetes_namespace.workspace,
#     kubernetes_manifest.cluster,
#     kubernetes_manifest.vcluster
#   ]
# }


# This is generated from the vcluster...
# Need to find a way for it to wait before running, so that the secret exists

# We'll need to use the kubeconfig from above to provision the coder/pair environment
resource "kubernetes_manifest" "ingress_capi_kubeapi" {
  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "Ingress"
    "metadata" = {
      "annotations" = {
        "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
        "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
      }
      "name"      = "kubeapi"
      "namespace" = data.coder_workspace.me.name
    }
    "spec" = {
      "ingressClassName" = "contour-external"
      "rules" = [
        {
          "host" = "${data.coder_workspace.me.name}.${var.base_domain}"
          "http" = {
            "paths" = [
              {
                "backend" = {
                  "service" = {
                    "name" = "vcluster1"
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
            "${data.coder_workspace.me.name}.${var.base_domain}"
          ]
        },
      ]
    }
  }
}
