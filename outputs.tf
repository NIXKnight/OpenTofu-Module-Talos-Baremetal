# ===============================================================================
# Talos Baremetal Module - Outputs
# ===============================================================================

# -------------------------------------------------------------------------------
# SENSITIVE CLUSTER ARTIFACTS (land in state - see README security section)
# -------------------------------------------------------------------------------

output "kubeconfig" {
  description = "Admin kubeconfig (cluster-admin credentials) for kubectl. Sensitive."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration (talosconfig) for talosctl. Endpoints/nodes are real CP IPs. Sensitive."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "client_configuration" {
  description = "Talos client_configuration object (CA + client cert/key). Needed to extend the cluster from other modules. Sensitive."
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "machine_secrets" {
  description = "Talos machine secrets (PKI and encryption keys). Needed to extend/rebuild config externally. Sensitive."
  value       = talos_machine_secrets.this.machine_secrets
  sensitive   = true
}

# -------------------------------------------------------------------------------
# RENDERED BASE CONFIG MAPS (pure locals - assertable without a live provider)
# -------------------------------------------------------------------------------
# Marked sensitive because they embed full machine configuration. The VIP appears
# ONLY in controlplane_config (under machine.network.interfaces[*].vip); never in
# worker_config. These exclude the Cilium inline render (a separate patch layer).

output "controlplane_config" {
  description = "Assembled control plane machine-config map per node (base config + L2 VIP). Sensitive."
  value       = local.controlplane_config
  sensitive   = true
}

output "worker_config" {
  description = "Assembled worker machine-config map per node (no VIP). Sensitive."
  value       = local.worker_config
  sensitive   = true
}

# -------------------------------------------------------------------------------
# CLUSTER FACTS
# -------------------------------------------------------------------------------

output "control_plane_ips" {
  description = "Map of control plane node name => IP address."
  value       = local.control_plane_ips
}

output "worker_ips" {
  description = "Map of worker node name => IP address."
  value       = local.worker_ips
}

output "control_plane_vip" {
  description = "The Kubernetes API VIP (Talos native Layer-2)."
  value       = var.control_plane_vip
}

output "api_endpoint" {
  description = "Kubernetes API endpoint served by the VIP (https://<vip>:6443)."
  value       = local.cluster_endpoint
}

output "bootstrap_endpoint_ip" {
  description = "REAL control plane IP used for bootstrap, kubeconfig and config-apply targeting. Always a node IP, never the VIP."
  value       = local.bootstrap_ip
}

output "node_count" {
  description = "Total number of cluster nodes (control planes + workers)."
  value       = length(var.control_planes) + length(var.workers)
}

output "control_plane_count" {
  description = "Number of control plane nodes."
  value       = length(var.control_planes)
}

output "cilium_deployed" {
  description = "Whether Cilium is installed by this module as the bootstrap CNI."
  value       = local.cilium_enabled
}

output "cilium_values" {
  description = "Effective (merged) Cilium Helm values rendered into the inline manifest. Includes kubeProxyReplacement=true and k8sServicePort=KubePrism (7445). Not sensitive."
  value       = local.cilium_merged_values
}

output "labels" {
  description = "Common labels passed to the module (surfaced for downstream tagging/automation)."
  value       = var.labels
}
