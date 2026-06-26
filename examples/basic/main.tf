#===============================================================================
# Example: basic - single control plane + single worker
#===============================================================================
# Smallest viable cluster. Nodes 192.168.10.11 (cp) and 192.168.10.21 (worker)
# must already be booted into Talos maintenance mode and keep these IPs after
# install. The VIP (192.168.10.10) must be in the same L2 subnet and outside DHCP.
#
# This is a single control plane: NOT highly available. Use examples/ha for HA.
#===============================================================================

module "talos" {
  source = "../.."

  cluster_name       = "lab-basic"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  # API HA VIP (Talos native Layer-2). In-subnet, outside the DHCP range.
  control_plane_vip = "192.168.10.10"
  vip_interface     = "eth0"

  control_planes = {
    "cp-1" = {
      ip           = "192.168.10.11"
      install_disk = "/dev/sda"
    }
  }

  workers = {
    "worker-1" = {
      ip           = "192.168.10.21"
      install_disk = "/dev/sda"
    }
  }

  # Single small cluster: let workloads run on the control plane too.
  allow_scheduling_on_control_planes = true

  # Cilium bootstrap CNI (default). Set deploy_cilium = false to bring your own.
  deploy_cilium  = true
  cilium_version = "1.19.5"
}

output "api_endpoint" {
  description = "Kubernetes API endpoint (VIP)."
  value       = module.talos.api_endpoint
}

output "node_count" {
  description = "Total node count."
  value       = module.talos.node_count
}

output "kubeconfig" {
  description = "Admin kubeconfig."
  value       = module.talos.kubeconfig
  sensitive   = true
}
