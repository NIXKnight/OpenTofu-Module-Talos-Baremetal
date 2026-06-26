#===============================================================================
# Example: ha - 3 control planes + 2 workers
#===============================================================================
# Highly available control plane: 3 nodes for etcd quorum, fronted by the Talos
# native Layer-2 VIP. All control planes MUST share one L2 subnet. Every node IP
# (and the VIP) is static/reserved, in-subnet, and the VIP is outside DHCP range.
#===============================================================================

module "talos" {
  source = "../.."

  cluster_name       = "lab-ha"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  # API HA VIP (Talos native Layer-2). In-subnet, outside the DHCP range.
  control_plane_vip = "192.168.20.10"
  vip_interface     = "eth0"

  control_planes = {
    "cp-1" = { ip = "192.168.20.11", install_disk = "/dev/nvme0n1" }
    "cp-2" = { ip = "192.168.20.12", install_disk = "/dev/nvme0n1" }
    "cp-3" = { ip = "192.168.20.13", install_disk = "/dev/nvme0n1" }
  }

  workers = {
    "worker-1" = {
      ip           = "192.168.20.21"
      install_disk = "/dev/sda"
      labels       = { "workload" = "general" }
    }
    "worker-2" = {
      ip           = "192.168.20.22"
      install_disk = "/dev/sda"
      labels       = { "workload" = "general" }
    }
  }

  # Day-2 friendly: stage reboot-requiring changes instead of applying live.
  apply_mode = "staged_if_needing_reboot"

  # Cilium bootstrap CNI with a couple of user value overrides (deep-merged).
  deploy_cilium  = true
  cilium_version = "1.19.5"
  cilium_values = {
    hubble = {
      enabled = true
      relay   = { enabled = true }
    }
  }
}

output "api_endpoint" {
  description = "Kubernetes API endpoint (VIP)."
  value       = module.talos.api_endpoint
}

output "control_plane_ips" {
  description = "Control plane node IPs."
  value       = module.talos.control_plane_ips
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

output "talosconfig" {
  description = "Talos client config for talosctl."
  value       = module.talos.talosconfig
  sensitive   = true
}
