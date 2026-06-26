# ===============================================================================
# Talos Baremetal Module - Cluster Bring-up Graph
# ===============================================================================
# Order:
#   secrets
#     -> machine configuration (control plane + worker, data)
#     -> client configuration (data; endpoints/nodes = REAL CP IPs, never the VIP)
#     -> config apply (control plane, then workers) to MAINTENANCE-MODE nodes
#     -> settle window (time_sleep)
#     -> bootstrap (first real CP IP)
#     -> post-bootstrap health gate (optional)
#     -> kubeconfig (first real CP IP)
#
# Initial apply targets each node's maintenance-mode IP. That apply installs Talos
# to disk and the node reboots into the configured state - this IS the documented
# initial-provisioning flow. No talosctl --insecure shim is required.
# ===============================================================================

# -------------------------------------------------------------------------------
# MACHINE SECRETS (PKI / tokens / encryption keys - generated at apply)
# -------------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version

  lifecycle {
    precondition {
      condition     = !contains(concat(values(local.control_plane_ips), values(local.worker_ips)), var.control_plane_vip)
      error_message = "control_plane_vip must not equal any control plane or worker node IP."
    }
    precondition {
      condition     = length(distinct(concat(values(local.control_plane_ips), values(local.worker_ips)))) == (length(var.control_planes) + length(var.workers))
      error_message = "All node IPs (control planes and workers combined) must be unique."
    }
  }
}

# -------------------------------------------------------------------------------
# MACHINE CONFIGURATION (data) - control plane
# -------------------------------------------------------------------------------
# cluster_endpoint is the VIP (https://<vip>:6443). config_patches layer:
#   1. base HCL config (yamlencode of local.controlplane_config - includes the VIP)
#   2. user inlineManifests (var.inline_manifests; Cilium installs via helm_release)
#   3. per-node patches (highest precedence)
data "talos_machine_configuration" "control_plane" {
  for_each = var.control_planes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    [yamlencode(local.controlplane_config[each.key])],
    local.inline_manifests_patches,
    local.controlplane_extra_patches[each.key],
  )

  docs     = false
  examples = false
}

# -------------------------------------------------------------------------------
# MACHINE CONFIGURATION (data) - workers (no VIP, no control plane components)
# -------------------------------------------------------------------------------
data "talos_machine_configuration" "worker" {
  for_each = var.workers

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    [yamlencode(local.worker_config[each.key])],
    local.worker_extra_patches[each.key],
  )

  docs     = false
  examples = false
}

# -------------------------------------------------------------------------------
# CLIENT CONFIGURATION (talosconfig) - REAL CP IPs only (never the VIP)
# -------------------------------------------------------------------------------
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration

  endpoints = values(local.control_plane_ips)
  nodes     = concat(values(local.control_plane_ips), values(local.worker_ips))
}

# -------------------------------------------------------------------------------
# APPLY CONFIG - control planes (targets each node's maintenance-mode IP)
# -------------------------------------------------------------------------------
resource "talos_machine_configuration_apply" "control_plane" {
  for_each = var.control_planes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane[each.key].machine_configuration

  node       = each.value.ip
  endpoint   = each.value.ip
  apply_mode = var.apply_mode

  # On destroy, wipe Talos from disk and reboot back into maintenance mode.
  # graceful=false avoids an etcd-leave deadlock when tearing down all members.
  on_destroy = {
    graceful = false
    reboot   = true
    reset    = true
  }
}

# -------------------------------------------------------------------------------
# APPLY CONFIG - workers (after control planes)
# -------------------------------------------------------------------------------
resource "talos_machine_configuration_apply" "worker" {
  for_each = var.workers

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration

  node       = each.value.ip
  endpoint   = each.value.ip
  apply_mode = var.apply_mode

  on_destroy = {
    graceful = false
    reboot   = true
    reset    = true
  }

  depends_on = [talos_machine_configuration_apply.control_plane]
}

# -------------------------------------------------------------------------------
# SETTLE WINDOW - let nodes install Talos and reboot before bootstrap
# -------------------------------------------------------------------------------
resource "time_sleep" "wait_for_boot" {
  depends_on      = [talos_machine_configuration_apply.control_plane]
  create_duration = "${var.wait_for_boot_seconds}s"
}

# -------------------------------------------------------------------------------
# BOOTSTRAP - one-time etcd/control-plane init on the FIRST REAL CP IP
# -------------------------------------------------------------------------------
# Never the VIP: the native L2 VIP relies on etcd leader election and is not
# active until AFTER bootstrap completes.
resource "talos_machine_bootstrap" "this" {
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_configuration_apply.control_plane,
    time_sleep.wait_for_boot,
  ]
}

# -------------------------------------------------------------------------------
# API READINESS POLL - wait for the Kubernetes API to answer after bootstrap
# -------------------------------------------------------------------------------
# The helm provider must reach the live API to install Cilium, but bootstrap can
# return before the apiserver is fully serving. Poll https://<cp>:6443/version on
# the first real CP IP until it responds. insecure: the API serving cert is not in
# the runner trust store. Only needed when this module installs Cilium.
data "http" "api_up" {
  count = local.cilium_enabled ? 1 : 0

  url      = "https://${local.bootstrap_ip}:6443/version"
  insecure = true

  retry {
    attempts = 60
  }

  depends_on = [talos_machine_bootstrap.this]
}

# -------------------------------------------------------------------------------
# KUBECONFIG - admin kubeconfig from the bootstrapped cluster (FIRST REAL CP IP)
# -------------------------------------------------------------------------------
# Fetching the kubeconfig is a Talos-API operation and does NOT need a working CNI,
# so it depends only on bootstrap (plus the API-up poll when Cilium is enabled). It
# deliberately does NOT wait on talos_cluster_health, which now runs AFTER the CNI
# (Talos #7967): gating kubeconfig on health would deadlock, because nodes stay
# NotReady until Cilium is installed.
resource "talos_cluster_kubeconfig" "this" {
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_bootstrap.this,
    data.http.api_up,
  ]
}

# -------------------------------------------------------------------------------
# CILIUM CNI - live Helm install AFTER bootstrap (replaces the inlineManifest path)
# -------------------------------------------------------------------------------
# The helm provider (versions.tf) is configured from talos_cluster_kubeconfig.this.
# Installing Cilium here - not via Talos cluster.inlineManifests - means day-2
# changes flow through `tofu apply` (helm upgrade). wait=true blocks until the
# release is healthy; nodes move NotReady -> Ready once the Cilium agents are up.
resource "helm_release" "cilium" {
  count = local.cilium_enabled ? 1 : 0

  name             = "cilium"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  values           = [yamlencode(local.cilium_merged_values)]
  wait             = true
  timeout          = var.cilium_helm_timeout
  atomic           = var.cilium_atomic

  depends_on = [
    talos_cluster_kubeconfig.this,
    data.http.api_up,
  ]
}

# -------------------------------------------------------------------------------
# HEALTH GATE (optional) - runs AFTER the CNI (Talos #7967 reorder)
# -------------------------------------------------------------------------------
# With Cilium delivered by helm_release instead of inlineManifests, nodes stay
# NotReady until Cilium is applied, so a health check before the CNI would
# deadlock. It therefore runs after helm_release.cilium, and also waits for workers
# to be applied/rebooted so the worker_nodes check does not run before they join.
# When Cilium is disabled (method "none"), set enable_health_check = false.
data "talos_cluster_health" "this" {
  count = var.enable_health_check ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = values(local.control_plane_ips)
  worker_nodes         = values(local.worker_ips)
  endpoints            = values(local.control_plane_ips)

  timeouts = {
    read = "${var.health_check_timeout_seconds}s"
  }

  depends_on = [
    helm_release.cilium,
    talos_machine_configuration_apply.worker,
  ]
}
