terraform {
  required_version = ">= 1.8.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

# The Talos module configures the helm provider internally (from the cluster
# kubeconfig) and installs Cilium via helm_release after bootstrap, so no root
# helm/http provider configuration is needed here. Note: because the module
# declares a provider, its module block cannot use count, for_each, or depends_on.
