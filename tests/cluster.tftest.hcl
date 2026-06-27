# ===============================================================================
# Unit tests - run with: tofu test
# ===============================================================================
# Fully mocked: no live providers, no real nodes. Verifies input validation
# (etcd quorum) and the rendered configuration / endpoint wiring. All asserted
# outputs are pure locals, so they are deterministic under mocked providers.
# ===============================================================================

mock_provider "talos" {
  # talos_cluster_kubeconfig.kubernetes_client_configuration feeds the helm
  # provider and the kubeconfig_data output, both of which base64decode the cert
  # fields. The default mock generates non-base64 strings, so pin valid base64
  # here (decodes to foo/bar/baz) to exercise the real decode path.
  mock_resource "talos_cluster_kubeconfig" {
    defaults = {
      kubernetes_client_configuration = {
        host               = "https://192.168.30.11:6443"
        ca_certificate     = "Zm9v"
        client_certificate = "YmFy"
        client_key         = "YmF6"
      }
    }
  }
}
mock_provider "helm" {}
mock_provider "http" {}
mock_provider "time" {}

# Common inputs shared by all runs (control_planes / workers set per run).
variables {
  cluster_name       = "test-cluster"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"
  control_plane_vip  = "192.168.30.10"
  vip_interface      = "eth0"
}

# -------------------------------------------------------------------------------
# Quorum validation MUST reject an even control plane count (2).
# -------------------------------------------------------------------------------
run "rejects_two_control_planes" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
      "cp-2" = { ip = "192.168.30.12" }
    }
  }

  expect_failures = [var.control_planes]
}

# -------------------------------------------------------------------------------
# Quorum validation MUST reject a count of 4.
# -------------------------------------------------------------------------------
run "rejects_four_control_planes" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
      "cp-2" = { ip = "192.168.30.12" }
      "cp-3" = { ip = "192.168.30.13" }
      "cp-4" = { ip = "192.168.30.14" }
    }
  }

  expect_failures = [var.control_planes]
}

# -------------------------------------------------------------------------------
# A valid 3-CP + 2-worker cluster: assert endpoint, CNI, VIP wiring, counts,
# and that the bootstrap target is a real CP IP (never the VIP).
# -------------------------------------------------------------------------------
run "valid_three_cp_cluster" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11", install_disk = "/dev/sda" }
      "cp-2" = { ip = "192.168.30.12", install_disk = "/dev/sda" }
      "cp-3" = { ip = "192.168.30.13", install_disk = "/dev/sda" }
    }
    workers = {
      "worker-1" = { ip = "192.168.30.21" }
      "worker-2" = { ip = "192.168.30.22" }
    }
  }

  # API endpoint is served by the VIP.
  assert {
    condition     = output.api_endpoint == "https://192.168.30.10:6443"
    error_message = "api_endpoint must be https://<vip>:6443."
  }

  # CNI disabled (Cilium replaces it).
  assert {
    condition     = nonsensitive(output.controlplane_config["cp-1"].cluster.network.cni.name) == "none"
    error_message = "control plane cluster.network.cni.name must be 'none'."
  }

  # kube-proxy disabled (Cilium replaces it).
  assert {
    condition     = nonsensitive(output.controlplane_config["cp-1"].cluster.proxy.disabled) == true
    error_message = "control plane cluster.proxy.disabled must be true."
  }

  # VIP wired into the control plane interface.
  assert {
    condition     = nonsensitive(output.controlplane_config["cp-1"].machine.network.interfaces[0].vip.ip) == "192.168.30.10"
    error_message = "control plane machine.network.interfaces[*].vip.ip must be the VIP."
  }

  # KubePrism enabled on :7445 (Cilium reaches the API via localhost:7445).
  assert {
    condition     = nonsensitive(output.controlplane_config["cp-1"].machine.features.kubePrism.port) == 7445
    error_message = "machine.features.kubePrism.port must be 7445."
  }

  # Workers must NOT carry the VIP anywhere.
  assert {
    condition     = !nonsensitive(strcontains(yamlencode(output.worker_config), "vip"))
    error_message = "worker_config must not contain a VIP."
  }

  # KubePrism is machine-level and MUST be present on workers too.
  assert {
    condition     = nonsensitive(output.worker_config["worker-1"].machine.features.kubePrism.port) == 7445
    error_message = "worker machine.features.kubePrism.port must be 7445."
  }

  # Workers must NOT carry control-plane-only kube-proxy settings.
  assert {
    condition     = !nonsensitive(strcontains(yamlencode(output.worker_config), "proxy:"))
    error_message = "worker_config must not contain cluster.proxy (control-plane-only)."
  }

  # Workers must NOT carry control-plane-only CNI settings.
  assert {
    condition     = !nonsensitive(strcontains(yamlencode(output.worker_config), "cni:"))
    error_message = "worker_config must not contain cluster.network.cni (control-plane-only)."
  }

  # Node count = 3 control planes + 2 workers.
  assert {
    condition     = output.node_count == 5
    error_message = "node_count must equal control planes + workers (5)."
  }

  assert {
    condition     = output.control_plane_count == 3
    error_message = "control_plane_count must be 3."
  }

  # Bootstrap/kubeconfig target is the first CP IP by sort order, NOT the VIP.
  assert {
    condition     = output.bootstrap_endpoint_ip == "192.168.30.11"
    error_message = "bootstrap_endpoint_ip must be the first control plane IP (192.168.30.11)."
  }

  assert {
    condition     = output.bootstrap_endpoint_ip != output.control_plane_vip
    error_message = "bootstrap target must never be the VIP."
  }

  # Cilium bootstrap CNI enabled by default.
  assert {
    condition     = output.cilium_deployed == true
    error_message = "cilium_deployed must be true by default."
  }

  # Cilium kube-proxy replacement: boolean true (NOT the deprecated "strict").
  assert {
    condition     = output.cilium_values.kubeProxyReplacement == true
    error_message = "Cilium kubeProxyReplacement must be boolean true."
  }

  # Cilium reaches the API via Talos KubePrism on localhost:7445.
  assert {
    condition     = output.cilium_values.k8sServiceHost == "localhost"
    error_message = "Cilium k8sServiceHost must be localhost (KubePrism)."
  }

  assert {
    condition     = output.cilium_values.k8sServicePort == 7445
    error_message = "Cilium k8sServicePort must be 7445 (KubePrism)."
  }

  # Talos assigns PodCIDRs to Node objects -> Kubernetes host-scope IPAM.
  assert {
    condition     = output.cilium_values.ipam.mode == "kubernetes"
    error_message = "Cilium ipam.mode must be kubernetes."
  }

  # CRITICAL consistency: Cilium k8sServicePort MUST equal KubePrism port.
  assert {
    condition     = output.cilium_values.k8sServicePort == nonsensitive(output.controlplane_config["cp-1"].machine.features.kubePrism.port)
    error_message = "Cilium k8sServicePort must equal machine.features.kubePrism.port (both 7445)."
  }

  # Cilium is delivered by an in-module helm_release (count 1 by default =
  # helm_release method), NOT via Talos inlineManifests.
  assert {
    condition     = length(helm_release.cilium) == 1
    error_message = "helm_release.cilium must be planned with count 1 when cilium_install_method is helm_release."
  }

  assert {
    condition     = helm_release.cilium[0].chart == "cilium"
    error_message = "helm_release.cilium chart must be 'cilium'."
  }

  assert {
    condition     = helm_release.cilium[0].namespace == "kube-system"
    error_message = "helm_release.cilium namespace must be kube-system."
  }

  # No 'cilium' inline manifest is produced: the control-plane config patches
  # carry only the base config (and any user inline_manifests), never Cilium.
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane["cp-1"].config_patches), "cilium")
    error_message = "control-plane config_patches must not contain a Cilium inline manifest."
  }
}

# -------------------------------------------------------------------------------
# A single control plane (count = 1) is valid for quorum.
# -------------------------------------------------------------------------------
run "valid_single_control_plane" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
    workers = {}
  }

  assert {
    condition     = output.node_count == 1
    error_message = "single node cluster must report node_count = 1."
  }

  assert {
    condition     = output.bootstrap_endpoint_ip == "192.168.30.11"
    error_message = "bootstrap target must be the sole control plane IP."
  }
}

# -------------------------------------------------------------------------------
# bootstrap_node override selects a specific control plane key.
# -------------------------------------------------------------------------------
run "bootstrap_node_override" {
  command = plan

  variables {
    bootstrap_node = "cp-3"
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
      "cp-2" = { ip = "192.168.30.12" }
      "cp-3" = { ip = "192.168.30.13" }
    }
  }

  assert {
    condition     = output.bootstrap_endpoint_ip == "192.168.30.13"
    error_message = "bootstrap_node override must select cp-3's IP (192.168.30.13)."
  }
}

# -------------------------------------------------------------------------------
# VIP colliding with a node IP MUST be rejected (resource precondition).
# -------------------------------------------------------------------------------
run "rejects_vip_node_ip_collision" {
  command = plan

  variables {
    control_plane_vip = "192.168.30.11"
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
  }

  expect_failures = [talos_machine_secrets.this]
}

# -------------------------------------------------------------------------------
# UUID (nodeID) disk encryption is wired onto STATE+EPHEMERAL of every node.
# -------------------------------------------------------------------------------
run "disk_encryption_nodeid" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
      "cp-2" = { ip = "192.168.30.12" }
      "cp-3" = { ip = "192.168.30.13" }
    }
    workers = {
      "worker-1" = { ip = "192.168.30.21" }
    }
    disk_encryption = {
      enabled      = true
      key_provider = "nodeID"
    }
  }

  # LUKS2 provider on the control plane STATE partition.
  assert {
    condition     = nonsensitive(output.controlplane_config["cp-1"].machine.systemDiskEncryption.state.provider) == "luks2"
    error_message = "control plane STATE encryption provider must be luks2."
  }

  # nodeID (uuid) key present on the control plane, and NOT kms/tpm.
  assert {
    condition     = nonsensitive(strcontains(yamlencode(output.controlplane_config["cp-1"].machine.systemDiskEncryption), "nodeID"))
    error_message = "control plane encryption must use the nodeID (uuid) key provider."
  }

  assert {
    condition     = !nonsensitive(strcontains(yamlencode(output.controlplane_config["cp-1"].machine.systemDiskEncryption), "kms"))
    error_message = "nodeID encryption must not emit a kms key."
  }

  # Encryption is machine-level, so workers are encrypted too (EPHEMERAL).
  assert {
    condition     = nonsensitive(output.worker_config["worker-1"].machine.systemDiskEncryption.ephemeral.provider) == "luks2"
    error_message = "worker EPHEMERAL encryption provider must be luks2."
  }

  assert {
    condition     = nonsensitive(strcontains(yamlencode(output.worker_config["worker-1"].machine.systemDiskEncryption), "nodeID"))
    error_message = "worker encryption must use the nodeID (uuid) key provider."
  }
}

# -------------------------------------------------------------------------------
# kms key provider without an endpoint MUST be rejected.
# -------------------------------------------------------------------------------
run "rejects_kms_without_endpoint" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
    disk_encryption = {
      enabled      = true
      key_provider = "kms"
    }
  }

  expect_failures = [var.disk_encryption]
}

# -------------------------------------------------------------------------------
# An unknown key provider MUST be rejected.
# -------------------------------------------------------------------------------
run "rejects_invalid_key_provider" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
    disk_encryption = {
      enabled      = true
      key_provider = "bogus"
    }
  }

  expect_failures = [var.disk_encryption]
}

# -------------------------------------------------------------------------------
# Bootstrap-critical Cilium keys are enforced and cannot be overridden.
# -------------------------------------------------------------------------------
run "cilium_critical_keys_locked" {
  command = plan

  variables {
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
    cilium_values = {
      kubeProxyReplacement = false
      k8sServiceHost       = "evil.example"
      k8sServicePort       = 9999
    }
  }

  assert {
    condition     = output.cilium_values.kubeProxyReplacement == true
    error_message = "kubeProxyReplacement must remain true even if a caller sets it false."
  }

  assert {
    condition     = output.cilium_values.k8sServiceHost == "localhost"
    error_message = "k8sServiceHost must remain localhost even if overridden."
  }

  assert {
    condition     = output.cilium_values.k8sServicePort == 7445
    error_message = "k8sServicePort must remain 7445 (KubePrism) even if overridden."
  }
}

# -------------------------------------------------------------------------------
# cilium_install_method = "none" disables the in-module Cilium helm_release
# (bring-your-own CNI): no helm_release is planned and cilium_deployed is false.
# -------------------------------------------------------------------------------
run "cilium_method_none" {
  command = plan

  variables {
    cilium_install_method = "none"
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
  }

  assert {
    condition     = length(helm_release.cilium) == 0
    error_message = "helm_release.cilium must have count 0 when cilium_install_method is 'none'."
  }

  assert {
    condition     = output.cilium_deployed == false
    error_message = "cilium_deployed must be false when cilium_install_method is 'none'."
  }
}

# -------------------------------------------------------------------------------
# Single-character cluster_name is accepted; labels are surfaced via output.
# -------------------------------------------------------------------------------
run "single_char_name_and_labels_output" {
  command = plan

  variables {
    cluster_name = "a"
    labels       = { env = "test" }
    control_planes = {
      "cp-1" = { ip = "192.168.30.11" }
    }
  }

  assert {
    condition     = output.node_count == 1
    error_message = "single-character cluster_name must be accepted and plan successfully."
  }

  assert {
    condition     = output.labels["env"] == "test"
    error_message = "labels output must surface the provided labels."
  }
}

# -------------------------------------------------------------------------------
# Talos CCM (node-csr-approval only) ENABLED: helm_release present, controllers
# scoped, and kubernetesTalosAPIAccess injected into the CONTROL-PLANE config only.
# -------------------------------------------------------------------------------
run "talos_ccm_csr_approver_enabled" {
  command = plan

  variables {
    control_planes         = { "cp-1" = { ip = "192.168.30.11" } }
    workers                = { "worker-1" = { ip = "192.168.30.21" } }
    talos_ccm_csr_approver = { enabled = true }
  }

  assert {
    condition     = length(helm_release.talos_ccm_csr_approver) == 1
    error_message = "helm_release.talos_ccm_csr_approver must be planned with count 1 when enabled."
  }

  assert {
    condition     = helm_release.talos_ccm_csr_approver[0].chart == "talos-cloud-controller-manager"
    error_message = "talos_ccm_csr_approver chart must be 'talos-cloud-controller-manager'."
  }

  assert {
    condition     = helm_release.talos_ccm_csr_approver[0].namespace == "kube-system"
    error_message = "talos_ccm_csr_approver namespace must be kube-system."
  }

  # Controllers scoped to ONLY node-csr-approval (no cloud-node / node-ipam).
  assert {
    condition     = length(output.talos_ccm_csr_approver_values.enabledControllers) == 1 && output.talos_ccm_csr_approver_values.enabledControllers[0] == "node-csr-approval"
    error_message = "enabledControllers must be scoped to ['node-csr-approval'] only."
  }

  assert {
    condition     = output.talos_ccm_csr_approver_deployed == true
    error_message = "talos_ccm_csr_approver_deployed must be true when enabled."
  }

  # Talos API access feature is injected into the CONTROL-PLANE machine config.
  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.control_plane["cp-1"].config_patches), "kubernetesTalosAPIAccess")
    error_message = "control-plane config must carry kubernetesTalosAPIAccess when enabled."
  }

  # CP-only: workers must NOT receive the Talos API access feature.
  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.worker["worker-1"].config_patches), "kubernetesTalosAPIAccess")
    error_message = "worker config must NOT carry kubernetesTalosAPIAccess (control-plane-only feature)."
  }
}

# -------------------------------------------------------------------------------
# Talos CCM DISABLED by default: no helm_release, and SECURITY - the Talos API is
# NOT opened (no kubernetesTalosAPIAccess) when the feature is off.
# -------------------------------------------------------------------------------
run "talos_ccm_csr_approver_disabled_by_default" {
  command = plan

  variables {
    control_planes = { "cp-1" = { ip = "192.168.30.11" } }
  }

  assert {
    condition     = length(helm_release.talos_ccm_csr_approver) == 0
    error_message = "helm_release.talos_ccm_csr_approver must have count 0 by default (opt-in)."
  }

  assert {
    condition     = output.talos_ccm_csr_approver_deployed == false
    error_message = "talos_ccm_csr_approver_deployed must be false by default."
  }

  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.control_plane["cp-1"].config_patches), "kubernetesTalosAPIAccess")
    error_message = "kubernetesTalosAPIAccess must be absent from the machine config when the approver is disabled."
  }
}

# -------------------------------------------------------------------------------
# replicas < 1 MUST be rejected.
# -------------------------------------------------------------------------------
run "rejects_talos_ccm_zero_replicas" {
  command = plan

  variables {
    control_planes         = { "cp-1" = { ip = "192.168.30.11" } }
    talos_ccm_csr_approver = { enabled = true, replicas = 0 }
  }

  expect_failures = [var.talos_ccm_csr_approver]
}

# -------------------------------------------------------------------------------
# A non-conforming values.enabledControllers override is REJECTED loudly (not swallowed).
# -------------------------------------------------------------------------------
run "rejects_talos_ccm_enabledcontrollers_override" {
  command = plan

  variables {
    control_planes = { "cp-1" = { ip = "192.168.30.11" } }
    talos_ccm_csr_approver = {
      enabled = true
      values  = { enabledControllers = ["cloud-node", "node-csr-approval", "node-ipam-controller"] }
    }
  }

  expect_failures = [var.talos_ccm_csr_approver]
}

# -------------------------------------------------------------------------------
# A --controllers flag smuggled via values.extraArgs is REJECTED (lock side channel).
# -------------------------------------------------------------------------------
run "rejects_talos_ccm_extraargs_controllers" {
  command = plan

  variables {
    control_planes = { "cp-1" = { ip = "192.168.30.11" } }
    talos_ccm_csr_approver = {
      enabled = true
      values  = { extraArgs = ["--controllers=cloud-node,node-csr-approval"] }
    }
  }

  expect_failures = [var.talos_ccm_csr_approver]
}

# -------------------------------------------------------------------------------
# DECOUPLED from Cilium: enabled with cilium_install_method = "none" still installs,
# and data.http.api_up is active (proves the readiness gate widening, fix 2).
# -------------------------------------------------------------------------------
run "talos_ccm_method_none_decoupled" {
  command = plan

  variables {
    control_planes         = { "cp-1" = { ip = "192.168.30.11" } }
    cilium_install_method  = "none"
    talos_ccm_csr_approver = { enabled = true }
  }

  assert {
    condition     = length(helm_release.talos_ccm_csr_approver) == 1
    error_message = "approver must install even when cilium_install_method is 'none'."
  }

  assert {
    condition     = length(data.http.api_up) == 1
    error_message = "data.http.api_up must be active (count 1) when the approver is enabled, even without Cilium."
  }
}

# -------------------------------------------------------------------------------
# Typed replicas maps through to the chart replicaCount.
# -------------------------------------------------------------------------------
run "talos_ccm_replicas_passthrough" {
  command = plan

  variables {
    control_planes         = { "cp-1" = { ip = "192.168.30.11" } }
    talos_ccm_csr_approver = { enabled = true, replicas = 3 }
  }

  assert {
    condition     = output.talos_ccm_csr_approver_values.replicaCount == 3
    error_message = "replicaCount must reflect the typed replicas (3)."
  }
}

# -------------------------------------------------------------------------------
# A values.replicaCount override is RE-LOCKED: the validated var.replicas wins, so 0
# cannot silently disable the approver while _deployed reports true (fix 4).
# -------------------------------------------------------------------------------
run "talos_ccm_replicacount_relocked" {
  command = plan

  variables {
    control_planes = { "cp-1" = { ip = "192.168.30.11" } }
    talos_ccm_csr_approver = {
      enabled = true
      values  = { replicaCount = 0 }
    }
  }

  assert {
    condition     = output.talos_ccm_csr_approver_values.replicaCount == 1
    error_message = "replicaCount must stay from var.replicas (default 1), not the values override (0)."
  }
}

# -------------------------------------------------------------------------------
# A legitimate values passthrough (nodeSelector) survives into the rendered release
# values, while enabledControllers stays locked (merge does not clobber legit input).
# -------------------------------------------------------------------------------
run "talos_ccm_values_passthrough_survives" {
  command = plan

  variables {
    control_planes = { "cp-1" = { ip = "192.168.30.11" } }
    talos_ccm_csr_approver = {
      enabled = true
      values  = { nodeSelector = { "node-role.kubernetes.io/control-plane" = "" } }
    }
  }

  assert {
    condition     = strcontains(join("", helm_release.talos_ccm_csr_approver[0].values), "nodeSelector")
    error_message = "a legitimate values passthrough (nodeSelector) must survive into the release values."
  }

  assert {
    condition     = output.talos_ccm_csr_approver_values.enabledControllers[0] == "node-csr-approval"
    error_message = "enabledControllers must stay locked while a passthrough value is merged."
  }
}

# -------------------------------------------------------------------------------
# External kubelets are REJECTED module-wide (no cloud-node to clear the taint, fix 6).
# -------------------------------------------------------------------------------
run "rejects_external_kubelet" {
  command = plan

  variables {
    control_planes     = { "cp-1" = { ip = "192.168.30.11" } }
    kubelet_extra_args = { "cloud-provider" = "external" }
  }

  expect_failures = [var.kubelet_extra_args]
}
