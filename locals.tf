# ===============================================================================
# Talos Baremetal Module - Computed Locals
# ===============================================================================
# Builds the full Talos machine configuration as HCL maps (control plane + worker)
# which main.tf yamlencode's into config_patches. Also computes endpoints, cert
# SANs, the Layer-2 VIP interface (control plane only), and the Cilium helm values.
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
  # The Kubernetes API endpoint baked into every machine config (and the kubeconfig).
  # Defaults to the VIP IP so all nodes (and external clients) reach a single,
  # etcd-elected API address. When var.api_endpoint_host is set, the endpoint becomes
  # that DNS name (which MUST resolve to the VIP); the VIP itself stays an IP. This is
  # only the machine-config endpoint - bootstrap/kubeconfig/apply still target real CP IPs.
  cluster_endpoint = "https://${coalesce(var.api_endpoint_host, var.control_plane_vip)}:6443"

  # -----------------------------------------------------------------------------
  # Control-plane / apiserver certificate SANs (VIP + all CP IPs + standard names +
  # the DNS endpoint host + user extras). Feeds machine.certSANs and apiServer.certSANs
  # on control planes. Workers use a narrower, node-scoped set (see worker_config).
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
    # null breaks concat before compact runs, so wrap as [] / [host] (not a bare null).
    var.api_endpoint_host == null ? [] : [var.api_endpoint_host],
  )))

  # -----------------------------------------------------------------------------
  # Shared machine fragments
  # -----------------------------------------------------------------------------
  talos_installer_image = "ghcr.io/siderolabs/installer:${var.talos_version}"

  # Talos >= 1.13 supports multi-document network config: the config generator emits a
  # default HostnameConfig{auto: stable} document, which conflicts with a v1alpha1
  # machine.network.hostname ("static hostname is already set in v1alpha1 config"). On
  # >= 1.13 we set the hostname via a HostnameConfig document (cp/worker_hostname_patches);
  # on <= 1.12 the generator uses the legacy machine.features.stableHostname path, so the
  # v1alpha1 hostname is correct there (and HostnameConfig is an unknown kind pre-1.13).
  # talos_version is validated as vX.Y.Z (variables.tf), so split always yields 3 parts.
  talos_version_major     = tonumber(split(".", trimprefix(var.talos_version, "v"))[0])
  talos_version_minor     = tonumber(split(".", trimprefix(var.talos_version, "v"))[1])
  talos_multidoc_hostname = local.talos_version_major > 1 || (local.talos_version_major == 1 && local.talos_version_minor >= 13)

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
          network = merge(
            {
              nameservers = var.nameservers
              interfaces  = [local.control_plane_vip_interfaces[key]]
            },
            # >= 1.13: hostname set via a HostnameConfig doc (cp_hostname_patches), NOT
            # v1alpha1. <= 1.12: keep the legacy v1alpha1 machine.network.hostname.
            local.talos_multidoc_hostname ? {} : { hostname = coalesce(cp.hostname, key) }
          )
          kubelet = {
            extraArgs = var.kubelet_extra_args
          }
          features = local.machine_features
          time     = { servers = var.ntp_servers }
        },
        # Per-node Kubernetes labels/annotations via Talos-native machine.nodeLabels /
        # machine.nodeAnnotations (reconciled day-2). Emitted only when non-empty - the
        # same conditional-merge idiom as machine_optional, applied per node.
        length(cp.labels) > 0 ? { nodeLabels = cp.labels } : {},
        length(cp.annotations) > 0 ? { nodeAnnotations = cp.annotations } : {},
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
        extraManifests = var.extra_manifests
        # inlineManifests are applied via a separate patch layer
        # (local.inline_manifests_patches, in main.tf) carrying only
        # var.inline_manifests, kept out of this pure, assertable local. Cilium is
        # no longer an inlineManifest - it installs via helm_release post-bootstrap.
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
          # Node-scoped Talos cert SANs: the worker's own hostname + IP, plus any operator
          # cert_sans and the DNS endpoint host (api_endpoint_host). Deliberately NOT
          # local.cert_sans, which carries apiserver identities (the VIP, CP IPs,
          # kubernetes.default.svc) that do not belong on a worker certificate.
          certSANs = distinct(compact(concat(
            [coalesce(w.hostname, key), w.ip],
            var.cert_sans,
            var.api_endpoint_host == null ? [] : [var.api_endpoint_host],
          )))
          network = merge(
            { nameservers = var.nameservers },
            # >= 1.13: hostname via worker_hostname_patches; <= 1.12: legacy v1alpha1.
            local.talos_multidoc_hostname ? {} : { hostname = coalesce(w.hostname, key) }
          )
          kubelet = merge(
            {
              extraArgs = var.kubelet_extra_args
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
        # Per-node Kubernetes labels/annotations via Talos-native machine.nodeLabels /
        # machine.nodeAnnotations (reconciled day-2). This REPLACES the old kubelet
        # --node-labels path; worker labels no longer flow through kubelet.extraArgs.
        # Emitted only when non-empty.
        length(w.labels) > 0 ? { nodeLabels = w.labels } : {},
        length(w.annotations) > 0 ? { nodeAnnotations = w.annotations } : {},
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
  # Per-node hostname as a Talos >= 1.13 HostnameConfig document (empty list on
  # <= 1.12, where the v1alpha1 machine.network.hostname is used instead).
  # -----------------------------------------------------------------------------
  # auto:"off" overrides the generator's default HostnameConfig{auto: stable} on the
  # same-(apiVersion,kind) document strategic merge (the patch's explicitly-set pointer
  # wins, even though Off is the zero enum value); the static `hostname` (highest
  # priority) becomes the node name. Yields a valid HostnameConfig{auto: off, hostname}.
  cp_hostname_patches = {
    for key, cp in var.control_planes : key => local.talos_multidoc_hostname ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = coalesce(cp.hostname, key)
    })] : []
  }
  worker_hostname_patches = {
    for key, w in var.workers : key => local.talos_multidoc_hostname ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = coalesce(w.hostname, key)
    })] : []
  }

  # -----------------------------------------------------------------------------
  # Cilium CNI values (fed to helm_release.cilium post-bootstrap in main.tf)
  # -----------------------------------------------------------------------------
  cilium_enabled = var.deploy_cilium && var.cilium_install_method == "helm_release"

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

  # Shallow merge: user top-level keys replace module defaults. The three
  # bootstrap-critical kube-proxy-replacement keys are RE-APPLIED last so they
  # cannot be overridden (k8sServicePort must stay == machine.features.kubePrism.port).
  cilium_merged_values = merge(
    merge(local.cilium_default_values, var.cilium_values),
    {
      kubeProxyReplacement = true
      k8sServiceHost       = "localhost"
      k8sServicePort       = 7445
    },
  )

  # User inline manifests only. Cilium is NOT injected here any more - it installs
  # via helm_release.cilium post-bootstrap (main.tf), so cluster.inlineManifests
  # carries just what the caller passes in var.inline_manifests. Applied as a single
  # control-plane patch in main.tf, kept out of controlplane_config so that output
  # stays a pure, assertable local.
  all_inline_manifests = var.inline_manifests

  inline_manifests_patches = length(local.all_inline_manifests) > 0 ? [
    yamlencode({
      cluster = {
        inlineManifests = local.all_inline_manifests
      }
    })
  ] : []

  # ---------------------------------------------------------------------------
  # Talos CCM scoped to node-csr-approval (kubelet serving-cert approval).
  # Optional; CONTROL-PLANE machine-config feature + helm_release AFTER Cilium.
  # ---------------------------------------------------------------------------
  talos_ccm_csr_approver_enabled = var.talos_ccm_csr_approver.enabled

  # CONTROL-PLANE-ONLY patch: open the Talos API to kube-system pods at os:reader so
  # the CCM can validate node CSRs. Closed by default (only when enabled). Merges
  # additively with machine.features.kubePrism from the base control-plane config.
  talos_api_access_patches = local.talos_ccm_csr_approver_enabled ? [
    yamlencode({
      machine = {
        features = {
          kubernetesTalosAPIAccess = {
            enabled                     = true
            allowedRoles                = ["os:reader"]
            allowedKubernetesNamespaces = ["kube-system"]
          }
        }
      }
    })
  ] : []

  talos_ccm_csr_approver_default_values = {
    enabledControllers = ["node-csr-approval"]
    replicaCount       = var.talos_ccm_csr_approver.replicas # chart key is replicaCount
  }

  # enabledControllers + replicaCount re-applied LAST (safety lock): a values blob must
  # never re-enable cloud-node / node-ipam, nor shadow the validated replica count.
  # Mirrors cilium_merged_values re-locking. (values.extraArgs and values.enabledControllers
  # are also rejected by variable validation - this merge is defense in depth.)
  talos_ccm_csr_approver_merged_values = merge(
    merge(local.talos_ccm_csr_approver_default_values, var.talos_ccm_csr_approver.values),
    {
      enabledControllers = ["node-csr-approval"]
      replicaCount       = var.talos_ccm_csr_approver.replicas
    },
  )
}
