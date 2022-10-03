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

# provider "kubernetes" {
#   alias                  = "vcluster"
#   host                   = yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["clusters"][0]["cluster"]["server"]
#   client_certificate     = base64decode(yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["users"][0]["user"]["client-certificate-data"])
#   client_key             = base64decode(yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["users"][0]["user"]["client-key-data"])
#   cluster_ca_certificate = base64decode(yamldecode(data.kubernetes_resource.kubeconfig.data)["value"]["clusters"][0]["cluster"]["certificate-authority-data"])
# }

variable "base_domain" {
  type    = string
  default = "test.pair.sharing.io"
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

resource "kubernetes_manifest" "configmap_vclusters_vcluster_init" {
  manifest = {
    "apiVersion" = "v1"
    "data" = {
      "cool.yaml" = <<-EOT
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: coder
        namespace: default
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: coder
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: cluster-admin
      subjects:
        - kind: ServiceAccount
          name: coder
          namespace: default
      ---
      apiVersion: apps/v1
      kind: StatefulSet
      metadata:
        name: code-server
        namespace: default
      spec:
        selector:
          matchLabels:
            app: code-server
        serviceName: code-server
        template:
          metadata:
            labels:
              app: code-server
          spec:
            serviceAccountName: coder
            securityContext:
              runAsUser: 1000
              fsGroup: 1000
            containers:
              - name: code-server
                image: codercom/enterprise-base:ubuntu
                command: ${jsonencode(["sh", "-c", coder_agent.main.init_script])}
                securityContext:
                  runAsUser: 1000
                env:
                  - name: CODER_AGENT_TOKEN
                    value: ${coder_agent.main.token}
      EOT
    }
    "kind" = "ConfigMap"
    "metadata" = {
      "name"      = "vcluster-instance-init"
      "namespace" = data.coder_workspace.me.name
    }
  }
}

resource "kubernetes_manifest" "clusterresourceset_vclusters_vcluster_init" {
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
          "name" = "vcluster-instance-init"
        },
      ]
      "strategy" = "ApplyOnce"
    }
  }
}

# This is generated from the vcluster...
# Need to find a way for it to wait before running, so that the secret exists

# We'll need to use the kubeconfig from above to provision the coder/pair environment
