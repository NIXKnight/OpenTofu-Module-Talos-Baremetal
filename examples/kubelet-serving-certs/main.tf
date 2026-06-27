#===============================================================================
# Example: kubelet-serving-certs - CA-signed kubelet serving certificates
#===============================================================================
# Issues CA-signed kubelet *serving* certificates cluster-wide so metrics-server,
# `kubectl top`, and other kubelet TLS scrapers work WITHOUT --kubelet-insecure-tls.
#
# TWO-KNOB recipe - BOTH are required; the approver is inert without the kubelet arg:
#   1. kubelet_extra_args.rotate-server-certificates = "true"  -> every kubelet
#      requests a CA-signed serving cert (submits a kubernetes.io/kubelet-serving CSR).
#   2. talos_ccm_csr_approver.enabled = true  -> installs the Talos cloud-controller-
#      manager scoped to ONLY the node-csr-approval controller, which validates each
#      CSR against Talos node metadata (matched by node name) and approves it.
#
# Opt-in, default-off. Notes:
#   - Enabling the approver injects a CONTROL-PLANE-only
#     machine.features.kubernetesTalosAPIAccess (os:reader, kube-system) so the CCM can
#     read the Talos API. Treat kube-system as a TRUSTED namespace - see the module
#     README "Privilege surface".
#   - Do NOT set kubelet --cloud-provider=external or cluster.externalCloudProvider:
#     this scoped CCM runs no cloud-node controller, so external kubelets would keep a
#     permanent node.cloudprovider.kubernetes.io/uninitialized taint. The module
#     REJECTS external kubelets by validation.
#   - rotate-server-certificates is a machine-config setting: enabling it on already-
#     installed nodes triggers a config-apply.
#
# See the module README "Kubelet serving certificates" section for the full rationale.
#===============================================================================

module "talos" {
  source = "../.."

  cluster_name       = "lab-serving-certs"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  # API HA VIP (Talos native Layer-2). In-subnet, outside the DHCP range.
  control_plane_vip = "192.168.50.10"
  vip_interface     = "eth0"

  control_planes = {
    "cp-1" = { ip = "192.168.50.11", install_disk = "/dev/nvme0n1" }
    "cp-2" = { ip = "192.168.50.12", install_disk = "/dev/nvme0n1" }
    "cp-3" = { ip = "192.168.50.13", install_disk = "/dev/nvme0n1" }
  }

  workers = {
    "worker-1" = { ip = "192.168.50.21", install_disk = "/dev/sda" }
  }

  # Knob 1 of 2: tell every kubelet to request a CA-signed serving cert. Without this
  # the approver has nothing to approve and kubelets keep self-signed certs.
  kubelet_extra_args = {
    "rotate-server-certificates" = "true"
  }

  # Knob 2 of 2: install the Talos CCM scoped to ONLY node-csr-approval to approve the
  # kubelet-serving CSRs. Opt-in / default-off. Optional fields shown commented.
  # NOTE: there are NO provider_regex / provider_ip_prefixes / bypass_dns_resolution
  # fields - talos-ccm validates against Talos node metadata, not regex/IP prefixes.
  talos_ccm_csr_approver = {
    enabled = true
    # replicas      = 1          # leader-elected; raise for HA
    # chart_version = "0.5.4"    # talos-cloud-controller-manager OCI chart
    # helm_timeout  = 600        # margin for first-enable secret-mint lag
    # values        = {}         # passthrough: nodeSelector/tolerations/resources/...
    #                            # (enabledControllers is locked to node-csr-approval)
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

output "talos_ccm_csr_approver_deployed" {
  description = "Whether the scoped Talos CCM (node-csr-approval) is installed."
  value       = module.talos.talos_ccm_csr_approver_deployed
}

output "kubeconfig" {
  description = "Admin kubeconfig."
  value       = module.talos.kubeconfig
  sensitive   = true
}
