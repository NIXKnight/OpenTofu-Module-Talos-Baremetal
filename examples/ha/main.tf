# ===============================================================================
# Example: ha - 3 control planes + 2 workers
# ===============================================================================
# Highly available control plane: 3 nodes for etcd quorum, fronted by the Talos
# native Layer-2 VIP. All control planes MUST share one L2 subnet. Every node IP
# (and the VIP) is static/reserved, in-subnet, and the VIP is outside DHCP range.
# ===============================================================================

module "talos" {
  source = "../.."

  cluster_name       = "lab-ha"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  # API HA VIP (Talos native Layer-2). In-subnet, outside the DHCP range.
  control_plane_vip = "192.168.20.10"
  vip_interface     = "eth0"

  # Optional DNS name for the API endpoint, layered on the VIP. It MUST resolve to
  # control_plane_vip at runtime (the VIP itself stays an IP). Baked into every machine
  # config (cluster.controlPlane.endpoint) and the generated kubeconfig, and auto-added
  # to the cert SANs so TLS validates against the name. Drop this line to use the VIP IP.
  api_endpoint_host = "api.lab-ha.example.com"

  control_planes = {
    # Per-node labels work on control planes too (Talos machine.nodeLabels).
    "cp-1" = {
      ip           = "192.168.20.11"
      install_disk = "/dev/nvme0n1"
      labels       = { "node.example.com/role" = "primary" }
    }
    "cp-2" = { ip = "192.168.20.12", install_disk = "/dev/nvme0n1" }
    "cp-3" = { ip = "192.168.20.13", install_disk = "/dev/nvme0n1" }
  }

  workers = {
    # Per-node hardware labels (Talos machine.nodeLabels) - schedule with a nodeSelector,
    # e.g. nodeSelector: { hardware.example.com/cpu: n100 }. Annotations are symmetric.
    "worker-1" = {
      ip           = "192.168.20.21"
      install_disk = "/dev/sda"
      labels       = { "workload" = "general", "hardware.example.com/cpu" = "n100" }
      annotations  = { "example.com/rack" = "rack-1" }
    }
    "worker-2" = {
      ip           = "192.168.20.22"
      install_disk = "/dev/sda"
      labels       = { "workload" = "general", "hardware.example.com/cpu" = "n305" }
      annotations  = { "example.com/rack" = "rack-2" }
    }
  }

  # Day-2 friendly: stage reboot-requiring changes instead of applying live.
  apply_mode = "staged_if_needing_reboot"

  # Cilium bootstrap CNI with a user value override (shallow merge; top-level keys
  # replace defaults, kube-proxy-replacement keys are enforced).
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
  description = "Kubernetes API endpoint."
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
