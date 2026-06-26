#===============================================================================
# Example: disk-encryption - UUID (nodeID) system disk encryption
#===============================================================================
# Encrypts the STATE and EPHEMERAL partitions on every node with LUKS2, using the
# "nodeID" key provider. The LUKS key is deterministically derived from each
# node's hardware UUID (SMBIOS) - no passphrase, no KMS, no TPM, and nothing
# secret stored in config or state. This protects data on drives physically
# removed from the node, and is the recommended baremetal mechanism.
#
# IMPORTANT: encryption is set at INITIAL provisioning. Enabling/changing it on an
# already-installed node requires a wipe (the partitions are re-created encrypted).
#
# Talos v1.13 reference:
#   https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-encryption
#===============================================================================

module "talos" {
  source = "../.."

  cluster_name       = "lab-encrypted"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  control_plane_vip = "192.168.40.10"
  vip_interface     = "eth0"

  control_planes = {
    "cp-1" = { ip = "192.168.40.11", install_disk = "/dev/nvme0n1" }
    "cp-2" = { ip = "192.168.40.12", install_disk = "/dev/nvme0n1" }
    "cp-3" = { ip = "192.168.40.13", install_disk = "/dev/nvme0n1" }
  }

  workers = {
    "worker-1" = { ip = "192.168.40.21", install_disk = "/dev/sda" }
  }

  # UUID-based disk encryption. key_provider defaults to "nodeID"; shown
  # explicitly here for clarity.
  disk_encryption = {
    enabled      = true
    key_provider = "nodeID"
    # Optional LUKS overrides (Talos defaults apply when omitted):
    # cipher     = "aes-xts-plain64"
    # block_size = 4096
  }
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
