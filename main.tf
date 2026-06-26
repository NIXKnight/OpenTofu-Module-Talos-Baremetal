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
    precondition {
      condition     = length(distinct([for m in local.all_inline_manifests : m.name])) == length(local.all_inline_manifests)
      error_message = "inline_manifests names must be unique and must not collide with the reserved 'cilium' inline manifest."
    }
  }
}

# -------------------------------------------------------------------------------
# CILIUM RENDER (template-only - renders the chart locally, never connects)
# -------------------------------------------------------------------------------
# data.helm_template mimics `helm template`: it renders manifests on the runner
# and exposes them as a string. kube_version is pinned so rendering needs NO
# cluster. The output is concatenated with var.inline_manifests into a single
# cluster.inlineManifests list (local.inline_manifests_patches) so Talos applies
# both user manifests and Cilium at bootstrap without one replacing the other.
data "helm_template" "cilium" {
  count = local.cilium_enabled ? 1 : 0

  name         = "cilium"
  namespace    = "kube-system"
  repository   = "https://helm.cilium.io"
  chart        = "cilium"
  version      = var.cilium_version
  kube_version = var.kubernetes_version
  include_crds = true

  values = [yamlencode(local.cilium_merged_values)]
}

# -------------------------------------------------------------------------------
# MACHINE CONFIGURATION (data) - control plane
# -------------------------------------------------------------------------------
# cluster_endpoint is the VIP (https://<vip>:6443). config_patches layer:
#   1. base HCL config (yamlencode of local.controlplane_config - includes the VIP)
#   2. combined inlineManifests (user manifests + Cilium, single list)
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
# HEALTH GATE (optional) - run ONLY AFTER bootstrap (avoids pre-bootstrap
# etcd deadlock, Talos #7967). Gates kubeconfig retrieval.
# -------------------------------------------------------------------------------
data "talos_cluster_health" "this" {
  count = var.enable_health_check ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = values(local.control_plane_ips)
  worker_nodes         = values(local.worker_ips)
  endpoints            = values(local.control_plane_ips)

  timeouts = {
    read = "${var.health_check_timeout_seconds}s"
  }

  # Wait for bootstrap AND for workers to be applied/rebooted, otherwise the
  # worker_nodes health check can run before workers have joined.
  depends_on = [
    talos_machine_bootstrap.this,
    talos_machine_configuration_apply.worker,
  ]
}

# -------------------------------------------------------------------------------
# KUBECONFIG - admin kubeconfig from the bootstrapped cluster (FIRST REAL CP IP)
# -------------------------------------------------------------------------------
resource "talos_cluster_kubeconfig" "this" {
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_bootstrap.this,
    data.talos_cluster_health.this,
  ]
}
