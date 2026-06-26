# ===============================================================================
# Talos Baremetal Module - Input Variables
# ===============================================================================
# Inputs are grouped:
#   1. Required cluster identity / versions
#   2. Node inventory (the baremetal pivot - no compute is created)
#   3. API HA (Talos native Layer-2 VIP)
#   4. Cluster networking
#   5. Machine tuning (disks, args, sysctls, kernel, registries, manifests)
#   6. Cilium bootstrap CNI
#   7. Operations (apply mode, bootstrap node, health gate, labels)
#   8. Optional disk encryption (KMS) - stub for v1
# ===============================================================================

# -------------------------------------------------------------------------------
# 1. REQUIRED CLUSTER IDENTITY / VERSIONS
# -------------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the Kubernetes cluster. Used for naming, labels, and a cert SAN."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.cluster_name)) && length(var.cluster_name) <= 32
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, start with a letter, end with alphanumeric, max 32 chars."
  }
}

variable "talos_version" {
  description = "Talos Linux version for the cluster (e.g. 'v1.13.5'). All nodes share one version for secret/PKI compatibility. REQUIRED."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_version))
    error_message = "talos_version must be in format vX.Y.Z (e.g. 'v1.13.5')."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version (e.g. '1.36.2'). Must be within the support range of the chosen talos_version. REQUIRED."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be in format X.Y.Z without a 'v' prefix (e.g. '1.36.2')."
  }
}

# -------------------------------------------------------------------------------
# 2. NODE INVENTORY (no compute created - machines must pre-exist)
# -------------------------------------------------------------------------------

variable "control_planes" {
  description = <<-EOT
    Map of control plane nodes, keyed by node name (e.g. "cp-1"). NO machines are
    created; each `ip` MUST already be reachable in Talos maintenance mode and must
    remain the node's stable address post-install (DHCP reservation by MAC or static).

    Per-node fields:
      - ip             (required) stable management IP, used in maintenance mode AND after install.
      - install_disk   (optional) target disk override; falls back to var.install_disk.
      - hostname       (optional) node hostname; falls back to the map key.
      - interface      (optional) NIC that hosts the VIP on this node; falls back to var.vip_interface.
      - config_patches (optional) extra Talos YAML config patches applied last (highest precedence).

    Count MUST be 1, 3, or 5 (etcd quorum). All control planes MUST share one L2 subnet.

    Example:
      {
        "cp-1" = { ip = "192.168.1.11", install_disk = "/dev/nvme0n1" }
        "cp-2" = { ip = "192.168.1.12" }
        "cp-3" = { ip = "192.168.1.13" }
      }
  EOT
  type = map(object({
    ip             = string
    install_disk   = optional(string)
    hostname       = optional(string)
    interface      = optional(string)
    config_patches = optional(list(string), [])
  }))

  validation {
    condition     = contains([1, 3, 5], length(var.control_planes))
    error_message = "control_planes count must be 1, 3, or 5 for etcd quorum (got a different number). Even counts and counts >5 are rejected."
  }

  validation {
    condition     = alltrue([for k, v in var.control_planes : can(regex("^[a-z][a-z0-9-]*$", k))])
    error_message = "control_planes keys must be lowercase alphanumeric with hyphens, starting with a letter."
  }

  validation {
    condition     = alltrue([for k, v in var.control_planes : can(cidrhost("${v.ip}/32", 0))])
    error_message = "Every control plane 'ip' must be a valid IPv4 address."
  }

  validation {
    condition     = length(distinct([for k, v in var.control_planes : v.ip])) == length(var.control_planes)
    error_message = "control_planes IP addresses must be unique."
  }
}

variable "workers" {
  description = <<-EOT
    Map of worker nodes, keyed by node name (e.g. "worker-1"). NO machines are created;
    each `ip` MUST already be reachable in Talos maintenance mode and remain stable
    post-install. Default is no workers.

    Per-node fields:
      - ip             (required) stable management IP.
      - install_disk   (optional) target disk override; falls back to var.install_disk.
      - hostname       (optional) node hostname; falls back to the map key.
      - labels         (optional) node labels applied via kubelet --node-labels.
      - taints         (optional) register-with taints (key/value/effect).
      - config_patches (optional) extra Talos YAML config patches applied last.

    Example:
      {
        "worker-1" = { ip = "192.168.1.21", labels = { "role" = "general" } }
        "worker-2" = { ip = "192.168.1.22", taints = [{ key = "dedicated", value = "gpu", effect = "NoSchedule" }] }
      }
  EOT
  type = map(object({
    ip           = string
    install_disk = optional(string)
    hostname     = optional(string)
    labels       = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string, "")
      effect = string
    })), [])
    config_patches = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.workers : can(regex("^[a-z][a-z0-9-]*$", k))])
    error_message = "workers keys must be lowercase alphanumeric with hyphens, starting with a letter."
  }

  validation {
    condition     = alltrue([for k, v in var.workers : can(cidrhost("${v.ip}/32", 0))])
    error_message = "Every worker 'ip' must be a valid IPv4 address."
  }

  validation {
    condition = alltrue([
      for k, v in var.workers : alltrue([
        for t in v.taints : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)
      ])
    ])
    error_message = "worker taint effect must be one of NoSchedule, PreferNoSchedule, NoExecute."
  }
}

# -------------------------------------------------------------------------------
# 3. API HA - TALOS NATIVE LAYER-2 VIP
# -------------------------------------------------------------------------------

variable "control_plane_vip" {
  description = <<-EOT
    Shared control plane API VIP (Talos native Layer-2 / ARP, etcd-elected). Serves the
    Kubernetes API endpoint only (https://<vip>:6443). It MUST sit inside the control
    plane L2 subnet and OUTSIDE any DHCP range. It is NOT active until AFTER bootstrap,
    so the module never targets it for apply/bootstrap/kubeconfig (those use real CP IPs).
  EOT
  type        = string

  validation {
    condition     = can(cidrhost("${var.control_plane_vip}/32", 0))
    error_message = "control_plane_vip must be a valid, non-empty IPv4 address."
  }
}

variable "vip_interface" {
  description = <<-EOT
    Default NIC that hosts the control plane VIP (e.g. 'eth0', 'eno1', 'enp1s0').
    Overridable per node via control_planes[*].interface. When null, the module uses a
    deviceSelector matching the first physical interface ({ physical = true }).
  EOT
  type        = string
  default     = null
}

variable "vip_interface_dhcp" {
  description = <<-EOT
    Whether the VIP-hosting interface is configured for DHCP (true, the default, matching
    the DHCP-reservation assumption) or left to user-supplied static addressing (false).
    Set false for static-IP nodes and provide addressing via control_planes[*].config_patches.
  EOT
  type        = bool
  default     = true
}

# -------------------------------------------------------------------------------
# 4. CLUSTER NETWORKING
# -------------------------------------------------------------------------------

variable "pod_cidr" {
  description = "Pod network CIDR."
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR block (e.g. '10.244.0.0/16')."
  }
}

variable "service_cidr" {
  description = "Service network CIDR."
  type        = string
  default     = "10.96.0.0/12"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid CIDR block (e.g. '10.96.0.0/12')."
  }
}

variable "cluster_domain" {
  description = "Cluster DNS domain."
  type        = string
  default     = "cluster.local"
}

variable "cert_sans" {
  description = "Additional certificate SANs (the VIP, all CP IPs, the endpoint host, and standard kubernetes names are added automatically)."
  type        = list(string)
  default     = []
}

variable "nameservers" {
  description = "DNS nameservers applied to every node."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ntp_servers" {
  description = "NTP servers applied to every node."
  type        = list(string)
  default     = ["pool.ntp.org"]
}

# -------------------------------------------------------------------------------
# 5. MACHINE TUNING
# -------------------------------------------------------------------------------

variable "install_disk" {
  description = "Default install disk for nodes that do not set a per-node install_disk."
  type        = string
  default     = "/dev/sda"
}

variable "apiserver_extra_args" {
  description = "Extra kube-apiserver flags (map of flag => value)."
  type        = map(string)
  default     = {}
}

variable "controller_manager_extra_args" {
  description = "Extra kube-controller-manager flags."
  type        = map(string)
  default     = {}
}

variable "scheduler_extra_args" {
  description = "Extra kube-scheduler flags."
  type        = map(string)
  default     = {}
}

variable "kubelet_extra_args" {
  description = "Extra kubelet flags applied to all nodes."
  type        = map(string)
  default     = {}
}

variable "sysctls" {
  description = "Additional machine.sysctls (merged over module defaults)."
  type        = map(string)
  default     = {}
}

variable "kernel_modules" {
  description = "Kernel modules to load on every node (Talos machine.kernel.modules)."
  type = list(object({
    name       = string
    parameters = optional(list(string))
  }))
  default = []
}

variable "registries" {
  description = "Talos machine.registries block (mirrors / config). Type 'any' to pass through verbatim."
  type        = any
  default     = {}
}

variable "extra_manifests" {
  description = "List of manifest URLs added to cluster.extraManifests (fetched by Talos at bootstrap)."
  type        = list(string)
  default     = []
}

variable "inline_manifests" {
  description = "List of inline manifests ({ name, contents }) added to cluster.inlineManifests (applied by Talos at bootstrap)."
  type = list(object({
    name     = string
    contents = string
  }))
  default = []
}

variable "allow_scheduling_on_control_planes" {
  description = "Allow workloads to schedule on control plane nodes (single-node / small clusters)."
  type        = bool
  default     = false
}

# -------------------------------------------------------------------------------
# 6. CILIUM BOOTSTRAP CNI
# -------------------------------------------------------------------------------

variable "deploy_cilium" {
  description = "Whether to install Cilium as the bootstrap CNI. When false, NO CNI is installed (bring your own)."
  type        = bool
  default     = true
}

variable "cilium_install_method" {
  description = <<-EOT
    How Cilium is installed:
      - "inline_manifest" : render the Cilium Helm chart locally (data.helm_template,
                            template-only, no cluster connection) and inject the rendered
                            manifests into Talos cluster.inlineManifests so Talos applies
                            them at bootstrap.
      - "none"            : do not install a CNI (bring your own).
  EOT
  type        = string
  default     = "inline_manifest"

  validation {
    condition     = contains(["inline_manifest", "none"], var.cilium_install_method)
    error_message = "cilium_install_method must be one of: inline_manifest, none."
  }
}

variable "cilium_version" {
  description = "Cilium Helm chart version (e.g. '1.19.5'). Used only when deploy_cilium is true and method is inline_manifest."
  type        = string
  default     = "1.19.5"
}

variable "cilium_values" {
  description = "User Helm values for Cilium, deep-merged over the module's Talos-tuned defaults (type 'any')."
  type        = any
  default     = {}
}

# -------------------------------------------------------------------------------
# 7. OPERATIONS
# -------------------------------------------------------------------------------

variable "apply_mode" {
  description = <<-EOT
    Talos machine_configuration_apply mode:
      - "auto"                       : apply immediately, reboot if required (default).
      - "staged"                     : stage config for the next boot.
      - "staged_if_needing_reboot"   : apply live when possible, stage only changes that
                                       need a reboot (recommended for day-2 to avoid surprise reboots).
  EOT
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "staged", "staged_if_needing_reboot"], var.apply_mode)
    error_message = "apply_mode must be one of: auto, staged, staged_if_needing_reboot."
  }
}

variable "bootstrap_node" {
  description = "Control plane map key to bootstrap and to target for kubeconfig. Defaults to the first key by sort order. Must be a key in control_planes."
  type        = string
  default     = null

  validation {
    condition     = var.bootstrap_node == null || contains(keys(var.control_planes), coalesce(var.bootstrap_node, "__unset__"))
    error_message = "bootstrap_node, when set, must be a key present in control_planes."
  }
}

variable "enable_health_check" {
  description = "Run data.talos_cluster_health AFTER bootstrap to gate kubeconfig retrieval. Disable for faster, less-verified applies."
  type        = bool
  default     = true
}

variable "health_check_timeout_seconds" {
  description = "Timeout for the post-bootstrap cluster health check."
  type        = number
  default     = 600

  validation {
    condition     = var.health_check_timeout_seconds > 0
    error_message = "health_check_timeout_seconds must be greater than 0."
  }
}

variable "wait_for_boot_seconds" {
  description = "Settle window (time_sleep) after control plane config apply before bootstrap, allowing nodes to install Talos and reboot."
  type        = number
  default     = 30

  validation {
    condition     = var.wait_for_boot_seconds >= 0
    error_message = "wait_for_boot_seconds must be >= 0."
  }
}

variable "labels" {
  description = "Common labels merged into module-managed metadata (informational; surfaced via outputs)."
  type        = map(string)
  default     = {}
}

# -------------------------------------------------------------------------------
# 8. OPTIONAL DISK ENCRYPTION (nodeID/uuid default; kms; tpm)
# -------------------------------------------------------------------------------

variable "disk_encryption" {
  description = <<-EOT
    Optional system disk encryption (LUKS2) for the STATE and EPHEMERAL partitions on
    EVERY node. Disabled by default. `key_provider` selects how the LUKS key is derived:

      - "nodeID" (default): key deterministically derived from the node's hardware UUID
                            (SMBIOS) plus the partition label. No external dependency or
                            stored secret - the recommended baremetal mechanism. This is
                            the "uuid" key provider.
      - "kms"             : key wrapped by a remote KMS endpoint (requires kms_endpoint).
      - "tpm"             : key sealed to the node's TPM 2.0 device.

    cipher / key_size / block_size are optional LUKS overrides (Talos defaults apply when
    left unset). NOTE: changing encryption settings on an already-installed node requires
    a wipe; apply this at initial provisioning. See examples/disk-encryption.

    Example (uuid / nodeID):
      disk_encryption = { enabled = true, key_provider = "nodeID" }
  EOT
  type = object({
    enabled      = optional(bool, false)
    key_provider = optional(string, "nodeID")
    kms_endpoint = optional(string)
    cipher       = optional(string)
    key_size     = optional(number)
    block_size   = optional(number)
  })
  default = {}

  validation {
    condition     = contains(["nodeID", "kms", "tpm"], try(var.disk_encryption.key_provider, "nodeID"))
    error_message = "disk_encryption.key_provider must be one of: nodeID, kms, tpm."
  }

  validation {
    condition = (
      !try(var.disk_encryption.enabled, false) ||
      try(var.disk_encryption.key_provider, "nodeID") != "kms" ||
      try(var.disk_encryption.kms_endpoint, null) != null
    )
    error_message = "disk_encryption.kms_endpoint is required when disk_encryption.key_provider is \"kms\"."
  }
}
