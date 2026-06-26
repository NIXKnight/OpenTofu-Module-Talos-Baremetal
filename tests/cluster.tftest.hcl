#===============================================================================
# Unit tests - run with: tofu test
#===============================================================================
# Fully mocked: no live providers, no real nodes. Verifies input validation
# (etcd quorum) and the rendered configuration / endpoint wiring. All asserted
# outputs are pure locals, so they are deterministic under mocked providers.
#===============================================================================

mock_provider "talos" {}
mock_provider "helm" {}
mock_provider "time" {}

# Common inputs shared by all runs (control_planes / workers set per run).
variables {
  cluster_name       = "test-cluster"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"
  control_plane_vip  = "192.168.30.10"
  vip_interface      = "eth0"
}

#-------------------------------------------------------------------------------
# Quorum validation MUST reject an even control plane count (2).
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# Quorum validation MUST reject a count of 4.
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# A valid 3-CP + 2-worker cluster: assert endpoint, CNI, VIP wiring, counts,
# and that the bootstrap target is a real CP IP (never the VIP).
#-------------------------------------------------------------------------------
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
}

#-------------------------------------------------------------------------------
# A single control plane (count = 1) is valid for quorum.
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# bootstrap_node override selects a specific control plane key.
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# VIP colliding with a node IP MUST be rejected (resource precondition).
#-------------------------------------------------------------------------------
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
