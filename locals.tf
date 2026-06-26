# ===============================================================================
# Talos Baremetal Module - Computed Locals
# ===============================================================================
# Builds the full Talos machine configuration as HCL maps (control plane + worker)
# which main.tf yamlencode's into config_patches. Also computes endpoints, cert
# SANs, the Layer-2 VIP interface (control plane only), and the Cilium inline render.
#
# Critical wiring rule (Talos native VIP relies on etcd, NOT active until AFTER
# bootstrap):
#   - cluster_endpoint (https://<vip>:6443) is used ONLY as the machine-config
#     cluster endpoint (cluster.controlPlane.endpoint).
#   - bootstrap / kubeconfig / config-apply / client-configuration ALL target REAL
#     control-plane node IPs (never the VIP). The default real target is the first
#     control plane by sort order, overridable via var.bootstrap_node.
# ===============================================================================

locals {
  # -----------------------------------------------------------------------------
  # Node maps and bootstrap target selection
  # -----------------------------------------------------------------------------
  control_plane_ips = { for k, v in var.control_planes : k => v.ip }
  worker_ips        = { for k, v in var.workers : k => v.ip }

  # Deterministic first control plane (sorted), overridable by var.bootstrap_node.
  first_cp_key = coalesce(var.bootstrap_node, sort(keys(var.control_planes))[0])

  # REAL node IP used for bootstrap, kubeconfig, config-apply targeting and
  # client-configuration endpoints/nodes. NEVER the VIP.
  bootstrap_ip = var.control_planes[local.first_cp_key].ip

  # -----------------------------------------------------------------------------
  # Endpoints
  # -----------------------------------------------------------------------------
  # The Kubernetes API endpoint baked into every machine config. Uses the VIP so
  # all nodes (and external clients) reach a single, etcd-elected API address.
  cluster_endpoint = "https://${var.control_plane_vip}:6443"

  # -----------------------------------------------------------------------------
  # Certificate SANs (VIP + all CP IPs + standard names + user extras)
  # -----------------------------------------------------------------------------
  cert_sans = distinct(compact(concat(
    [var.control_plane_vip],
    values(local.control_plane_ips),
    [
      var.cluster_name,
      "localhost",
      "kubernetes",
      "kubernetes.default",
      "kubernetes.default.svc",
      "kubernetes.default.svc.${var.cluster_domain}",
    ],
    var.cert_sans,
  )))

  # -----------------------------------------------------------------------------
  # Shared machine fragments
  # -----------------------------------------------------------------------------
  talos_installer_image = "ghcr.io/siderolabs/installer:${var.talos_version}"

  # machine.features - KubePrism (local API proxy on :7445) is required so Cilium
  # can reach the API via k8sServiceHost=localhost without a working CNI/VIP yet.
  machine_features = {
    kubePrism = {
      enabled = true
      port    = 7445
    }
    hostDNS = {
      enabled              = true
      forwardKubeDNSToHost = true
    }
  }

  all_sysctls = merge({}, var.sysctls)

  # Optional machine fragments - included only when non-empty so the rendered
  # config stays clean (and assertable as a pure local).
  kernel_fragment     = length(var.kernel_modules) > 0 ? { kernel = { modules = var.kernel_modules } } : {}
  sysctls_fragment    = length(local.all_sysctls) > 0 ? { sysctls = local.all_sysctls } : {}
  registries_fragment = try(length(var.registries), 0) > 0 ? { registries = var.registries } : {}

  # Disk encryption (LUKS2). key_provider selects how the LUKS key is derived
  # (Talos v1.13 docs: reference/configuration/block encryption keys[]):
  #   nodeID -> deterministically derived from the node hardware UUID ("uuid"
  #             mechanism; no stored secret, recommended for baremetal)
  #   kms    -> sealed/unsealed by a remote KMS endpoint
  #   tpm    -> sealed to the node TPM 2.0 device
  disk_encryption_key_provider = try(var.disk_encryption.key_provider, "nodeID")

  # Exactly one provider fragment is non-empty; merged with the slot. Separate
  # conditional fragments avoid a ternary type-unification error.
  disk_encryption_key = try(var.disk_encryption.enabled, false) ? merge(
    { slot = 0 },
    local.disk_encryption_key_provider == "nodeID" ? { nodeID = {} } : {},
    local.disk_encryption_key_provider == "tpm" ? { tpm = {} } : {},
    local.disk_encryption_key_provider == "kms" ? { kms = { endpoint = var.disk_encryption.kms_endpoint } } : {},
  ) : null

  disk_encryption_partition = try(var.disk_encryption.enabled, false) ? merge(
    {
      provider = "luks2"
      keys     = [local.disk_encryption_key]
    },
    try(var.disk_encryption.cipher, null) != null ? { cipher = var.disk_encryption.cipher } : {},
    try(var.disk_encryption.key_size, null) != null ? { keySize = var.disk_encryption.key_size } : {},
    try(var.disk_encryption.block_size, null) != null ? { blockSize = var.disk_encryption.block_size } : {},
  ) : null

  # Encrypt STATE (secrets/certs) and EPHEMERAL (workload data) on every node.
  disk_encryption_config = try(var.disk_encryption.enabled, false) ? {
    state     = local.disk_encryption_partition
    ephemeral = local.disk_encryption_partition
  } : null

  disk_encryption_fragment = local.disk_encryption_config != null ? { systemDiskEncryption = local.disk_encryption_config } : {}

  machine_optional = merge(
    local.kernel_fragment,
    local.sysctls_fragment,
    local.registries_fragment,
    local.disk_encryption_fragment,
  )

  # -----------------------------------------------------------------------------
  # Control plane VIP interface (CONTROL PLANE ONLY - inline Talos L2 VIP)
  # -----------------------------------------------------------------------------
  # Per-node interface override (control_planes[*].interface) > var.vip_interface.
  # When neither is set, fall back to a physical-interface deviceSelector.
  cp_vip_iface_name = { for k, cp in var.control_planes : k => try(coalesce(cp.interface, var.vip_interface), null) }

  control_plane_vip_interfaces = {
    for k, cp in var.control_planes : k => merge(
      {
        dhcp = var.vip_interface_dhcp
        vip  = { ip = var.control_plane_vip }
      },
      # Named interface when provided, otherwise a physical-interface deviceSelector.
      # Two separate conditional fragments avoid a ternary type-unification error.
      local.cp_vip_iface_name[k] != null ? { interface = local.cp_vip_iface_name[k] } : {},
      local.cp_vip_iface_name[k] == null ? { deviceSelector = { physical = true } } : {},
    )
  }

  # -----------------------------------------------------------------------------
  # Control plane machine configuration (HCL map -> yamlencode in main.tf)
  # -----------------------------------------------------------------------------
  controlplane_config = {
    for key, cp in var.control_planes : key => {
      machine = merge(
        {
          install = {
            disk  = coalesce(cp.install_disk, var.install_disk)
            image = local.talos_installer_image
          }
          certSANs = local.cert_sans
          network = {
            hostname    = coalesce(cp.hostname, key)
            nameservers = var.nameservers
            interfaces  = [local.control_plane_vip_interfaces[key]]
          }
          kubelet = {
            extraArgs = var.kubelet_extra_args
          }
          features = local.machine_features
          time     = { servers = var.ntp_servers }
        },
        local.machine_optional,
      )
      cluster = {
        allowSchedulingOnControlPlanes = var.allow_scheduling_on_control_planes
        network = {
          dnsDomain      = var.cluster_domain
          podSubnets     = [var.pod_cidr]
          serviceSubnets = [var.service_cidr]
          # Cilium replaces both kube-proxy and the in-tree CNI.
          cni = { name = "none" }
        }
        proxy = { disabled = true }
        apiServer = {
          certSANs  = local.cert_sans
          extraArgs = var.apiserver_extra_args
        }
        controllerManager = { extraArgs = var.controller_manager_extra_args }
        scheduler         = { extraArgs = var.scheduler_extra_args }
        discovery = {
          enabled = true
          registries = {
            kubernetes = { disabled = false }
            service    = { disabled = true }
          }
        }
        extraManifests  = var.extra_manifests
        inlineManifests = var.inline_manifests
      }
    }
  }

  # -----------------------------------------------------------------------------
  # Worker machine configuration (HCL map -> yamlencode in main.tf)
  # No VIP, no etcd/apiServer/controllerManager/scheduler.
  # -----------------------------------------------------------------------------
  worker_config = {
    for key, w in var.workers : key => {
      machine = merge(
        {
          install = {
            disk  = coalesce(w.install_disk, var.install_disk)
            image = local.talos_installer_image
          }
          network = {
            hostname    = coalesce(w.hostname, key)
            nameservers = var.nameservers
          }
          kubelet = merge(
            {
              extraArgs = merge(
                var.kubelet_extra_args,
                length(w.labels) > 0 ? { "node-labels" = join(",", [for lk, lv in w.labels : "${lk}=${lv}"]) } : {},
              )
            },
            length(w.taints) > 0 ? {
              extraConfig = {
                registerWithTaints = [for t in w.taints : { key = t.key, value = t.value, effect = t.effect }]
              }
            } : {},
          )
          features = local.machine_features
          time     = { servers = var.ntp_servers }
        },
        local.machine_optional,
      )
      # Worker cluster section is intentionally minimal. dnsDomain / podSubnets /
      # serviceSubnets are kept so a custom cluster_domain or pod/service CIDR
      # propagates to the worker kubelet (cluster DNS). CNI (cluster.network.cni)
      # and kube-proxy (cluster.proxy) are cluster-wide, CONTROL-PLANE-only
      # settings - they are deliberately NOT set on workers.
      cluster = {
        network = {
          dnsDomain      = var.cluster_domain
          podSubnets     = [var.pod_cidr]
          serviceSubnets = [var.service_cidr]
        }
      }
    }
  }

  # -----------------------------------------------------------------------------
  # Per-node extra config patches (applied last = highest precedence)
  # -----------------------------------------------------------------------------
  controlplane_extra_patches = { for k, cp in var.control_planes : k => cp.config_patches }
  worker_extra_patches       = { for k, w in var.workers : k => w.config_patches }

  # -----------------------------------------------------------------------------
  # Cilium bootstrap CNI (template-only render -> Talos inlineManifests)
  # -----------------------------------------------------------------------------
  cilium_enabled = var.deploy_cilium && var.cilium_install_method == "inline_manifest"

  # Talos-required Cilium values. kube-proxy + in-tree CNI are disabled in Talos,
  # so Cilium MUST take over service LB (kubeProxyReplacement) and reach the API
  # through KubePrism (localhost:7445). The securityContext capabilities and
  # cgroup settings are mandatory for Cilium to run under Talos' locked-down model.
  # ipam / routingMode / encryption / hubble etc. are left to cilium_values.
  cilium_default_values = {
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445
    operator = {
      replicas = length(var.control_planes) > 1 ? 2 : 1
    }
    ipam = {
      mode = "kubernetes"
    }
    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN",
          "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID",
        ]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }
  }

  # Shallow merge: user-provided top-level keys override module defaults.
  cilium_merged_values = merge(local.cilium_default_values, var.cilium_values)

  # Rendered Cilium manifests injected as a SEPARATE control-plane config patch
  # (kept out of controlplane_config so that output stays a pure, assertable local).
  cilium_config_patches = local.cilium_enabled ? [
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            name     = "cilium"
            contents = data.helm_template.cilium[0].manifest
          }
        ]
      }
    })
  ] : []
}
