# Talos Linux on Baremetal — OpenTofu Module

Provision a [Talos Linux](https://www.talos.dev/) Kubernetes cluster on **pre-existing physical machines**. This module creates **no compute**. It takes an inventory of machines that are already running in **Talos maintenance mode** and drives them through the full bring-up: secrets → machine config → apply → bootstrap → kubeconfig, with an HA API served by the **Talos native Layer-2 VIP** and an optional **Cilium CNI** installed via a live `helm_release` after bootstrap.

It is the baremetal counterpart to cloud Talos modules: the Talos secrets/config/bootstrap/kubeconfig core is preserved, while all cloud mechanics (server creation, `user_data` injection, cloud-API VIP failover, cloud CCM/CSI) are removed.

---

## Architecture

| Concern | Approach |
|---|---|
| **Provisioning** | **Maintenance-mode apply.** Nodes are booted into Talos maintenance mode out-of-band (PXE/USB/ISO — *not* this module's job). `talos_machine_configuration_apply` targets each node's maintenance-mode IP; that apply installs Talos to disk and the node reboots into the configured state. No `talosctl --insecure` shim. |
| **API HA** | **Talos native Layer-2 VIP** (ARP, etcd-elected). The VIP serves the Kubernetes API endpoint only (`https://<vip>:6443`). It is applied inline under `machine.network.interfaces[*].vip` on control planes. |
| **CNI / kube-proxy** | `cluster.network.cni.name = "none"` and `cluster.proxy.disabled = true`. Cilium replaces both. KubePrism is enabled on `:7445` so Cilium reaches the API via `localhost:7445` before the VIP/CNI are up. |
| **Cilium** | Optional CNI installed as a **live `helm_release` AFTER bootstrap** (not Talos `inlineManifests`). The module configures the `helm` provider internally from the cluster kubeconfig, so day-2 changes flow through `tofu apply` (`helm upgrade`). |

### The VIP / bootstrap rule (important)

The native VIP relies on **etcd leader election** and is **not active until AFTER bootstrap**. Therefore the module uses the VIP **only** as the machine-config API endpoint. Every operation that must reach a live node — `talos_machine_configuration_apply`, `talos_machine_bootstrap`, `talos_client_configuration`, `talos_cluster_kubeconfig`, `talos_cluster_health` — targets a **real control-plane node IP**, never the VIP. The default target is the first control plane by sort order (`sort(keys(control_planes))[0]`), overridable with `bootstrap_node`.

### Bring-up graph

```
talos_machine_secrets
  → data.talos_machine_configuration.control_plane / .worker   (cluster_endpoint = https://<vip>:6443)
  → data.talos_client_configuration                            (endpoints/nodes = REAL CP IPs)
  → talos_machine_configuration_apply.control_plane            (node/endpoint = each CP IP, maintenance mode)
  → talos_machine_configuration_apply.worker                   (after control planes)
  → time_sleep.wait_for_boot                                   (install + reboot settle window)
  → talos_machine_bootstrap                                    (first REAL CP IP)
  → data.http.api_up            [when Cilium enabled]          (poll https://<cp>:6443/version)
  → talos_cluster_kubeconfig                                   (first REAL CP IP; no CNI needed)
  → helm_release.cilium         [when Cilium enabled]          (live CNI install; nodes go Ready)
  → data.talos_cluster_health   [optional, AFTER Cilium]       (node readiness needs the CNI, Talos #7967)
```

> **Health-gate reorder (Talos [#7967](https://github.com/siderolabs/talos/issues/7967)).** With Cilium delivered by `helm_release` instead of `inlineManifests`, nodes stay **NotReady** until Cilium is installed. So `talos_cluster_health` now runs **after** `helm_release.cilium`, while `talos_cluster_kubeconfig` depends only on bootstrap (fetching a kubeconfig is a Talos-API operation that needs no CNI). A health check placed before the CNI would deadlock.

> **Module provider limitation (important).** This module **configures the `helm` provider internally** (from the cluster kubeconfig) to install Cilium. Because a module that declares its own provider configuration cannot be combined with `count`, `for_each`, or `depends_on`, **you cannot use those meta-arguments on this module block.** To stand up many clusters, instantiate the module multiple times explicitly, or set `cilium_install_method = "none"` and run Cilium from your own root module / provider.

---

## Prerequisites

1. **Nodes pre-booted into Talos maintenance mode** (out-of-band via PXE/USB/ISO). This module does **not** image machines or manage BMC/IPMI/netboot. Each machine must be reachable on its IP and answering the Talos API in maintenance mode before `apply`.
2. **All control planes on the SAME Layer-2 subnet.** The native VIP uses gratuitous ARP; it cannot cross subnets/routers.
3. **One stable IP per node.** Each node keeps a single management IP — via DHCP reservation (by MAC) or static configuration — used **both** in maintenance mode **and** after install. That IP is what you put in `control_planes[*].ip` / `workers[*].ip`.
4. **VIP placement.** `control_plane_vip` must sit **inside the control-plane subnet** and **outside any DHCP range**, and must not equal any node IP. Only the node-IP collision is machine-enforced (a precondition); subnet membership, DHCP-range exclusion, and pod/service CIDR non-overlap are **the operator's responsibility** (OpenTofu has no core CIDR-membership function to validate them reliably). The same applies to `pod_cidr`/`service_cidr` not overlapping.
5. **Tooling.** OpenTofu `>= 1.8.0`. Providers are resolved automatically (see [Requirements](#requirements)). Cilium is installed as a **live `helm_release` after bootstrap**: the runner pulls the chart from `helm.cilium.io` **and** must be able to reach the cluster API (the module configures the `helm` provider from the kubeconfig it fetches).

---

## Usage

### Basic — 1 control plane + 1 worker

```hcl
module "talos" {
  source = "github.com/<org>/OpenTofu-Module-Talos-Baremetal" # or a local path

  cluster_name       = "lab-basic"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  control_plane_vip = "192.168.10.10" # in-subnet, outside DHCP
  vip_interface     = "eth0"

  control_planes = {
    "cp-1" = { ip = "192.168.10.11", install_disk = "/dev/sda" }
  }
  workers = {
    "worker-1" = { ip = "192.168.10.21", install_disk = "/dev/sda" }
  }

  allow_scheduling_on_control_planes = true
}
```

### HA — 3 control planes + workers

```hcl
module "talos" {
  source = "github.com/<org>/OpenTofu-Module-Talos-Baremetal"

  cluster_name       = "lab-ha"
  talos_version      = "v1.13.5"
  kubernetes_version = "1.36.2"

  control_plane_vip = "192.168.20.10"
  vip_interface     = "eth0"

  control_planes = {
    "cp-1" = { ip = "192.168.20.11", install_disk = "/dev/nvme0n1" }
    "cp-2" = { ip = "192.168.20.12", install_disk = "/dev/nvme0n1" }
    "cp-3" = { ip = "192.168.20.13", install_disk = "/dev/nvme0n1" }
  }
  workers = {
    "worker-1" = { ip = "192.168.20.21" }
    "worker-2" = { ip = "192.168.20.22" }
  }

  apply_mode = "staged_if_needing_reboot" # day-2 friendly

  deploy_cilium = true
  cilium_values = {
    hubble = { enabled = true, relay = { enabled = true } }
  }
}
```

Runnable copies live in [`examples/basic`](examples/basic), [`examples/ha`](examples/ha), and [`examples/disk-encryption`](examples/disk-encryption) (UUID / `nodeID` LUKS2 encryption).

> Heterogeneous NICs: if a node's VIP interface differs (e.g. `eno1` vs `enp1s0`), set it per node with `control_planes["cp-x"].interface`. Leave `vip_interface` unset to use a physical-interface `deviceSelector` instead of a fixed name.

---

## Requirements

| Name | Version |
|---|---|
| OpenTofu | `>= 1.8.0` (`>= 1.11` only for the write-only secret-hardening path below) |
| `siderolabs/talos` | `~> 0.11.0` |
| `hashicorp/helm` | `~> 3.0` (live; installs Cilium via `helm_release` post-bootstrap) |
| `hashicorp/http` | `~> 3.0` (post-bootstrap Kubernetes API readiness poll) |
| `hashicorp/time` | `~> 0.9` |

Default versions in the examples: Talos `v1.13.5`, Kubernetes `1.36.2`, Cilium chart `1.19.5`. Confirm the Talos ↔ Kubernetes pairing against the [Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/).

---

## Inputs

### Required

| Name | Type | Description |
|---|---|---|
| `cluster_name` | `string` | Cluster name (lowercase, `[a-z0-9-]`, ≤32). |
| `talos_version` | `string` | Talos version, `vX.Y.Z` (e.g. `v1.13.5`). |
| `kubernetes_version` | `string` | Kubernetes version, `X.Y.Z` (no `v`). |
| `control_planes` | `map(object)` | Control plane inventory; **count must be 1, 3, or 5** (etcd quorum). Fields: `ip` (required), `install_disk?`, `hostname?`, `interface?`, `config_patches?`. |
| `control_plane_vip` | `string` | API VIP (in-subnet, outside DHCP, not a node IP). |

### Node / VIP options

| Name | Type | Default | Description |
|---|---|---|---|
| `workers` | `map(object)` | `{}` | Worker inventory. Fields: `ip` (required), `install_disk?`, `hostname?`, `labels?`, `taints?`, `config_patches?`. |
| `vip_interface` | `string` | `null` | Default NIC hosting the VIP. `null` → physical-interface `deviceSelector`. |
| `vip_interface_dhcp` | `bool` | `true` | Whether the VIP interface uses DHCP. Set `false` for static nodes and supply addressing via `config_patches`. |
| `bootstrap_node` | `string` | `null` | Control-plane key to bootstrap / fetch kubeconfig from. Defaults to first by sort order. |

### Networking

| Name | Type | Default | Description |
|---|---|---|---|
| `pod_cidr` | `string` | `10.244.0.0/16` | Pod CIDR. |
| `service_cidr` | `string` | `10.96.0.0/12` | Service CIDR. |
| `cluster_domain` | `string` | `cluster.local` | Cluster DNS domain. |
| `cert_sans` | `list(string)` | `[]` | Extra cert SANs (VIP + CP IPs + standard names added automatically). |
| `nameservers` | `list(string)` | `["1.1.1.1","8.8.8.8"]` | DNS servers. |
| `ntp_servers` | `list(string)` | `["pool.ntp.org"]` | NTP servers. |

### Machine tuning

| Name | Type | Default | Description |
|---|---|---|---|
| `install_disk` | `string` | `/dev/sda` | Default install disk (per-node override available). |
| `apiserver_extra_args` | `map(string)` | `{}` | kube-apiserver flags. |
| `controller_manager_extra_args` | `map(string)` | `{}` | kube-controller-manager flags. |
| `scheduler_extra_args` | `map(string)` | `{}` | kube-scheduler flags. |
| `kubelet_extra_args` | `map(string)` | `{}` | kubelet flags (all nodes). |
| `sysctls` | `map(string)` | `{}` | Extra `machine.sysctls`. |
| `kernel_modules` | `list(object({name, parameters?}))` | `[]` | Kernel modules to load. |
| `registries` | `any` | `{}` | `machine.registries` (mirrors/config), passed through. |
| `extra_manifests` | `list(string)` | `[]` | Manifest URLs (`cluster.extraManifests`). |
| `inline_manifests` | `list(object({name, contents}))` | `[]` | Inline manifests (`cluster.inlineManifests`). |
| `allow_scheduling_on_control_planes` | `bool` | `false` | Schedule workloads on control planes. |

### Cilium

| Name | Type | Default | Description |
|---|---|---|---|
| `deploy_cilium` | `bool` | `true` | Install Cilium as the cluster CNI (via `helm_release`). `false` = no CNI (BYO). |
| `cilium_install_method` | `string` | `helm_release` | `helm_release` (live install after bootstrap) or `none` (BYO CNI). |
| `cilium_version` | `string` | `1.19.5` | Cilium Helm chart version. |
| `cilium_helm_timeout` | `number` | `600` | Timeout (seconds) for the Cilium `helm_release`. |
| `cilium_atomic` | `bool` | `true` | Roll back the Cilium release on a failed install/upgrade. |
| `cilium_values` | `any` | `{}` | User Helm values. **Shallow merge** — top-level keys replace defaults. The kube-proxy-replacement keys (`kubeProxyReplacement`, `k8sServiceHost`, `k8sServicePort`) are **enforced and cannot be overridden**. |

> **kube-proxy is OFF by default.** The module hardcodes `cluster.proxy.disabled = true` and `cluster.network.cni.name = "none"` on the control plane (cluster-wide). When `deploy_cilium = true`, Cilium takes over with `kubeProxyReplacement = true` reaching the API via KubePrism (`localhost:7445`). **When `deploy_cilium = false` (BYO CNI), kube-proxy stays disabled** — your replacement CNI MUST provide service load-balancing itself (e.g. Cilium/Calico kube-proxy replacement), or you must re-enable kube-proxy via a `config_patch` (`cluster.proxy.disabled = false`). The module never ships kube-proxy on any default path.

### Kubelet serving certificates

| Name | Type | Default | Description |
|---|---|---|---|
| `talos_ccm_csr_approver` | `object` | `{ enabled = false }` | Optional Talos CCM scoped to the `node-csr-approval` controller, issuing CA-signed kubelet serving certs (drops `--kubelet-insecure-tls`). Fields: `enabled`, `chart_version` (`0.5.4`), `replicas` (`1`), `helm_timeout` (`600`), `atomic` (`true`), `values`. **Pair with `kubelet_extra_args = { "rotate-server-certificates" = "true" }`.** See [Kubelet serving certificates](#kubelet-serving-certificates-1). |

### Operations / security

| Name | Type | Default | Description |
|---|---|---|---|
| `apply_mode` | `string` | `auto` | `auto`, `staged`, or `staged_if_needing_reboot`. |
| `enable_health_check` | `bool` | `true` | Run `talos_cluster_health` after bootstrap to gate kubeconfig. |
| `health_check_timeout_seconds` | `number` | `600` | Health check read timeout. |
| `wait_for_boot_seconds` | `number` | `30` | Settle window after CP apply before bootstrap. |
| `labels` | `map(string)` | `{}` | Informational labels surfaced via outputs. |
| `disk_encryption` | `object` | `{ enabled = false }` | Optional LUKS2 STATE+EPHEMERAL encryption. `key_provider` ∈ `nodeID` (uuid, default) / `kms` / `tpm`. See [Disk encryption](#disk-encryption). |

---

## Disk encryption

Optional LUKS2 encryption for the **STATE** (secrets/certs) and **EPHEMERAL** (workload data) partitions on **every** node. Disabled by default; enable with `disk_encryption.enabled = true`. The `key_provider` chooses how the LUKS key is derived (see the Talos v1.13 [disk-encryption docs](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-encryption) and the [config block reference](https://docs.siderolabs.com/talos/v1.13/reference/configuration/block/rawvolumeconfig)):

| `key_provider` | How the key is derived | Notes |
|---|---|---|
| `nodeID` (default) | Deterministically from the node **hardware UUID** (SMBIOS) + partition label | The **"uuid" mechanism**. No stored secret, no external dependency, no TPM. Recommended for baremetal; protects data on drives removed from the node. |
| `kms` | Sealed/unsealed by a remote KMS endpoint | Requires `disk_encryption.kms_endpoint`. |
| `tpm` | Sealed to the node **TPM 2.0** device | Requires TPM 2.0 (typically with SecureBoot). |

```hcl
# UUID (nodeID) encryption — no secrets anywhere:
disk_encryption = {
  enabled      = true
  key_provider = "nodeID"
  # cipher / key_size / block_size are optional LUKS overrides; Talos defaults apply when unset.
}
```

The module renders this as `machine.systemDiskEncryption.{state,ephemeral}` with `provider: luks2` and a single `nodeID: {}` / `kms` / `tpm` key in slot 0. A full walkthrough is in [`examples/disk-encryption`](examples/disk-encryption).

> **Set encryption at INITIAL provisioning.** The partitions are created encrypted during the maintenance-mode install. Enabling or changing encryption on an already-installed node requires a wipe.
>
> **Note (v1.13):** Talos also supports the newer multi-document `VolumeConfig` form (`kind: VolumeConfig`, `name: STATE`/`EPHEMERAL`) for the same `nodeID`/`kms`/`tpm` keys. This module uses the strategic-merge `machine.systemDiskEncryption` form (also valid in v1.13); if you need `VolumeConfig`-managed user volumes, layer those via `inline_manifests` or a separate config document.

---

## Kubelet serving certificates

*Talos CCM scoped to the `node-csr-approval` controller — nothing else.*

By default kubelet uses a **self-signed** serving certificate, so `metrics-server`, `kubectl top`, and any kubelet TLS scraper need `--kubelet-insecure-tls`. To get **CA-signed** kubelet serving certs cluster-wide, set **two independent knobs**:

**1. Tell kubelets to request a serving cert** (operator-set, explicit — applies to every node):

```hcl
kubelet_extra_args = {
  "rotate-server-certificates" = "true"
}
```

Without this, kubelets keep self-signed certs and submit no serving CSRs. The module does **not** set it automatically: it mutates the machine config and triggers a config-apply/reboot, so it stays a deliberate operator choice.

**2. Approve the `kubernetes.io/kubelet-serving` CSRs:**

```hcl
talos_ccm_csr_approver = {
  enabled = true
}
```

This installs the Talos cloud-controller-manager **scoped to only the `node-csr-approval` controller**. It validates each serving CSR against Talos node metadata (matched by node **name**) and approves it; kube-controller-manager refuses to auto-approve serving CSRs, so an approver is mandatory.

With both set: kubelets submit serving CSRs → the approver signs them → `metrics-server` runs with **no** `--kubelet-insecure-tls`.

### Safety — do NOT make kubelets external

The scoped install runs **only** `node-csr-approval`; it does **not** run `cloud-node`, so it does not clear the `node.cloudprovider.kubernetes.io/uninitialized` taint. The module **rejects** external kubelets (a validation fails if `kubelet_extra_args` sets `cloud-provider = "external"`), and you must **not** set `cluster.externalCloudProvider` either — external kubelets would be tainted `uninitialized` with nothing to clear it, leaving nodes unschedulable. Re-enabling `cloud-node` would be harmless **only** while kubelets stay non-external (which the module enforces).

Controller scope is enforced two ways: the `enabledControllers` values key is **locked** to `["node-csr-approval"]`, **and** validation rejects a non-conforming `values.enabledControllers` or a `--controllers` flag in `values.extraArgs` (the chart passes `extraArgs` verbatim as container args, which would otherwise bypass the lock). This scoped CCM is **mutually exclusive** with running a full Talos CCM that includes the `cloud-node` controller — run one or the other, not both.

### Privilege surface

Enabling the approver injects `machine.features.kubernetesTalosAPIAccess` into the **control-plane** machine config (a config-apply on toggle). Understand the real blast radius before enabling: once the feature is on, **any** workload or ServiceAccount able to create a `serviceaccounts.talos.dev` object in `kube-system` can self-mint an `os:reader` talosconfig to the control-plane host Talos API. That grants read access to node/COSI resources (node and cluster metadata, `dmesg`, `talosctl read` of host files) and — depending on the method grants of `os:reader` — the **machine configuration**, which embeds the cluster CA and credentials. The scope is read-only (`os:reader`) and `kube-system`-only, but treat `kube-system` as a trusted namespace and keep tenant/untrusted workloads out of it. Closed by default — nothing is opened unless `enabled = true`.

> **Residual chart privilege.** The CCM ServiceAccount's chart ClusterRole grants `nodes` update/patch, `nodes/status` patch, `serviceaccounts` create, and `serviceaccounts/token` create **cluster-wide**, even though only `node-csr-approval` actually runs. This cannot be trimmed without forking the chart — it is a residual privilege of installing the upstream chart.

### Inputs (`talos_ccm_csr_approver`)

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `false` | Install the scoped Talos CCM. |
| `chart_version` | `string` | `0.5.4` | `talos-cloud-controller-manager` OCI chart version. |
| `replicas` | `number` | `1` | CCM replica count (leader-elected; raise for HA). |
| `helm_timeout` | `number` | `600` | Helm release timeout (seconds). Raised to leave margin for first-enable secret-mint lag. |
| `atomic` | `bool` | `true` | Roll back on a failed install/upgrade. |
| `values` | `any` | `{}` | Helm values passthrough (`nodeSelector` / `tolerations` / `resources` / pod or serviceAccount annotations). `enabledControllers` is locked to `["node-csr-approval"]`. |

> **Node labels / annotations: none required.** `node-csr-approval` maps the Kubernetes Node to the Talos node purely **by node name** — no `providerID`, label, or annotation is used. Cloud-CCM concerns from cloud modules (`providerID`, `node.kubernetes.io/exclude-from-external-load-balancers`, instance metadata) do **not** apply to baremetal and are intentionally not set. Per-node user labels remain available via `workers[*].labels`.

> **First enable / day-2 toggle.** The first time you set `enabled = true`, the `talos.dev` secret Talos mints for the CCM can lag briefly behind the helm install. If the release times out on that first apply, **re-apply** — it self-heals (`kubernetesTalosAPIAccess` is a runtime feature, no reboot). `helm_timeout` defaults to `600` to leave margin.

> **Optional digest pin.** The module pins the chart by semver (`chart_version`, default `0.5.4`) for readability. For stronger supply-chain provenance, verify and pin the chart digest out of band — e.g. `helm pull oci://ghcr.io/siderolabs/charts/talos-cloud-controller-manager --version 0.5.4` and record the `@sha256:` digest, or wrap the module against a digest-qualified OCI reference.

---

## Outputs

| Name | Sensitive | Description |
|---|:---:|---|
| `kubeconfig` | ✅ | Admin kubeconfig (cluster-admin). |
| `kubeconfig_data` | ✅ | Decoded API connection fields (`host`, `cluster_ca_certificate`, `client_certificate`, `client_key`) for wiring your own kubernetes/helm providers. |
| `talosconfig` | ✅ | Talos client config for `talosctl` (real CP IPs). |
| `client_configuration` | ✅ | Talos `client_configuration` (CA + client cert/key). |
| `machine_secrets` | ✅ | Talos machine secrets (PKI / encryption keys). |
| `controlplane_config` | ✅ | Assembled control-plane machine-config map (base + VIP). |
| `worker_config` | ✅ | Assembled worker machine-config map (no VIP). |
| `control_plane_ips` | | Map of CP name → IP. |
| `worker_ips` | | Map of worker name → IP. |
| `control_plane_vip` | | The API VIP. |
| `api_endpoint` | | `https://<vip>:6443`. |
| `bootstrap_endpoint_ip` | | Real CP IP used for bootstrap/kubeconfig (never the VIP). |
| `node_count` | | Control planes + workers. |
| `control_plane_count` | | Control plane count. |
| `cilium_deployed` | | Whether Cilium is installed by this module (`helm_release`). |
| `talos_ccm_csr_approver_deployed` | | Whether the scoped Talos CCM (node-csr-approval) is installed. |
| `talos_ccm_csr_approver_values` | | Effective merged Helm values for the Talos CCM release. |

---

## Day-2 operations

- **Avoid surprise reboots.** Set `apply_mode = "staged_if_needing_reboot"` so reboot-only changes are staged for the next boot rather than triggering an immediate, live reboot.
- **Adding nodes.** Add a key to `control_planes` (keep the count at 1/3/5) or `workers` and re-apply. New nodes must already be in maintenance mode on their target IP. New control planes join via Talos discovery after their config is applied.
- **Removing nodes.** Remove the key and apply. `on_destroy` resets the node (wipes Talos) and reboots it back to maintenance mode. Removing a control plane shrinks etcd — keep the remaining count at 1/3/5 and remove one member at a time. Do **not** remove the `bootstrap_node` key while it is still elected; re-point `bootstrap_node` first.
- **Cilium runs as an in-module `helm_release`.** It is installed live after bootstrap and its lifecycle is owned by this module: changing `cilium_values` / `cilium_version` and running `tofu apply` performs a `helm upgrade`. Setting `deploy_cilium = false` (or `cilium_install_method = "none"`) **uninstalls** the release on the next apply.
  - **`tofu destroy` needs the cluster reachable** to uninstall Cilium first. If the cluster is already gone, drop the release from state with `tofu state rm 'helm_release.cilium'` before destroying the rest, otherwise destroy blocks trying to talk to a dead API.
  - To hand Cilium to a separate GitOps/Helm pipeline (Argo CD / Flux) instead, set `cilium_install_method = "none"` and manage the CNI entirely from that layer.
- **Upgrades.** Talos and Kubernetes version bumps are applied through the same config/apply flow; review the Talos upgrade docs and bump `talos_version` / `kubernetes_version` deliberately (one minor at a time).

---

## Security

- **Secrets land in state.** `machine_secrets`, `client_configuration`, `talosconfig`, and `kubeconfig` are full credentials. They are all marked `sensitive`, but **OpenTofu state itself holds them in plaintext.** Use an encrypted remote backend with strict access control, or the hardening path below.
- **Hardening path (OpenTofu ≥ 1.11).** Keep PKI out of state by combining:
  - `ephemeral` `talos_machine_secrets` (generated per-run, never persisted), with
  - the **write-only** apply inputs `client_configuration_wo` / `machine_configuration_input_wo` (the `_wo` variants are not stored in state), sourcing the secret material from an `ephemeral "vault_*"` resource / external KMS.

  This removes long-lived PKI from state at the cost of regenerating ephemeral material each run and a higher floor (OpenTofu ≥ 1.11). v1 of this module uses the standard in-state flow for broad compatibility; adopt the `_wo` path when your toolchain and secret store support it.
- **No secrets in source.** This module generates all secrets at apply time. Do not commit `*.tfvars` containing credentials (the bundled `.gitignore` excludes `*.tfvars`).

---

## Baremetal caveats

- **No compute lifecycle.** Power, firmware, netboot, disk wipe-on-reinstall, and BMC are out of scope. If a node is *not* in maintenance mode (e.g. already installed), the initial apply will not behave like a fresh install — reset it to maintenance mode first.
- **Single L2 domain for control planes** is mandatory for the VIP. Spanning subnets needs an external L4 load balancer instead (not provided here).
- **Disk names are physical.** `/dev/sda` vs `/dev/nvme0n1` vs `/dev/vda` vary by hardware; set `install_disk` per node. Wrong disk = wiped data.
- **Static-IP nodes:** set `vip_interface_dhcp = false` and provide addressing via `control_planes[*].config_patches` (Talos owns the interface once installed).
- **Cilium install is live.** The chart is pulled on the runner and applied to the cluster via `helm_release` after bootstrap, so the runner must reach **both** `helm.cilium.io` and the cluster API. Air-gapped runners need a mirrored chart (override `repository` via a fork).
- **BYO CNI (`cilium_install_method = "none"`).** No CNI is installed; nodes stay **NotReady** until you apply one yourself. Set `enable_health_check = false` so the apply does not block on node readiness.
- **Cilium routing.** The module leaves `routingMode` unset → Cilium's default **tunnel (VXLAN)** datapath, the baremetal-safe choice across L2/L3. **native** routing is opt-in via `cilium_values` and requires an L2-adjacent pod CIDR or BGP to advertise pod routes.

---

## Manual end-to-end verification runbook

CI covers `fmt`, `init`, `validate`, and a fully-mocked `tofu test`. A real apply needs physical nodes in maintenance mode and is therefore **out of CI scope**. To verify against real hardware:

1. **Image nodes.** Boot every target machine into Talos **maintenance mode** (matching `talos_version`) via PXE/USB/ISO. Confirm each answers the Talos API: `talosctl -n <node-ip> --insecure version` (the `--insecure` here is talosctl's, used only for this out-of-band check — the module itself does not need it).
2. **Reserve addressing.** DHCP-reserve or statically assign each node IP; choose a `control_plane_vip` in-subnet and outside DHCP.
3. **Plan.** `tofu plan` and confirm: `cluster_endpoint` is `https://<vip>:6443`; apply / bootstrap / kubeconfig target real CP IPs; CNI is `none`; kube-proxy disabled.
4. **Apply.** `tofu apply`. Nodes install Talos and reboot into the configured state; the first control plane is bootstrapped; the health gate waits for the API.
5. **Talos health.** `talosctl --talosconfig <(tofu output -raw talosconfig) -n <cp-ip> health`.
6. **Kubernetes.** `tofu output -raw kubeconfig > kubeconfig && KUBECONFIG=kubeconfig kubectl get nodes -o wide` — nodes go `Ready` once Cilium is up. `kubectl -n kube-system get pods` shows `cilium*`.
7. **VIP failover (HA).** Confirm the API answers on the VIP (`kubectl --server https://<vip>:6443 get --raw=/healthz`), then reboot the elected control plane and confirm the VIP migrates and the API stays reachable.
8. **Teardown.** `tofu destroy` resets each node (wipe) and reboots it back to maintenance mode, ready for re-provision.
