# ===============================================================================
# Talos Baremetal Module - Provider Requirements
# ===============================================================================
# This module provisions a Talos Linux Kubernetes cluster on PRE-EXISTING
# baremetal machines. It creates NO compute. Nodes must already be booted into
# Talos maintenance mode (out-of-band via PXE/USB/ISO) before apply.
#
# Provider set, reduced from the cloud reference module which carried
# hcloud/tls/random/kubectl as well:
#   - siderolabs/talos : machine secrets, config, apply, bootstrap, kubeconfig
#   - hashicorp/helm    : LIVE install of Cilium via helm_release AFTER bootstrap.
#                         Configured internally (below) against the cluster
#                         kubeconfig - it connects to the running cluster.
#   - hashicorp/http    : post-bootstrap Kubernetes API readiness poll (api_up)
#                         before the helm provider connects.
#   - hashicorp/time    : post-apply settle window before bootstrap
#
# required_version is >= 1.8.0 for broad compatibility. The opt-in secret
# hardening path (client_configuration_wo / machine_configuration_input_wo +
# ephemeral talos_machine_secrets) documented in README.md requires >= 1.11.
# ===============================================================================

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

# -------------------------------------------------------------------------------
# HELM PROVIDER (LIVE) - configured against the cluster kubeconfig
# -------------------------------------------------------------------------------
# helm_release.cilium (main.tf) installs Cilium into the bootstrapped cluster, so
# the provider must reach the live API. Connection details come from the Talos-
# issued admin kubeconfig (talos_cluster_kubeconfig.this): the three cert fields
# are base64-encoded and decoded here; host is used as-is (helm provider v3
# attribute form).
#
# Because this module declares a provider configuration, the module block CANNOT
# be used with count, for_each, or depends_on (Terraform limitation). The try()
# fallbacks keep plan/validate working before the kubeconfig resource exists.
provider "helm" {
  kubernetes = {
    host                   = try(talos_cluster_kubeconfig.this.kubernetes_client_configuration.host, "https://localhost:6443")
    cluster_ca_certificate = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate), "")
    client_certificate     = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate), "")
    client_key             = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key), "")
  }
}
