# ===============================================================================
# Talos Baremetal Module - Provider Requirements
# ===============================================================================
# This module provisions a Talos Linux Kubernetes cluster on PRE-EXISTING
# baremetal machines. It creates NO compute. Nodes must already be booted into
# Talos maintenance mode (out-of-band via PXE/USB/ISO) before apply.
#
# Provider set (3 functional + 1 template-only), reduced from the cloud
# reference module which carried hcloud/tls/random/kubectl as well:
#   - siderolabs/talos : machine secrets, config, apply, bootstrap, kubeconfig
#   - hashicorp/time    : post-apply settle window before bootstrap
#   - hashicorp/helm    : TEMPLATE-ONLY rendering of Cilium (never connects to a
#                         cluster; data.helm_template renders the chart locally)
#   - hashicorp/http    : available for optional external readiness probes
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
      version = "~> 3.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
