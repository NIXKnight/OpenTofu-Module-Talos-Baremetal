# Talos Linux on Baremetal — OpenTofu Module

Provision a [Talos Linux](https://www.talos.dev/) Kubernetes cluster on **pre-existing
physical machines**. This module creates **no compute**. It takes an inventory of
machines that are already running in **Talos maintenance mode** and drives them through
the full bring-up: secrets → machine config → apply → bootstrap → kubeconfig, with an
HA API served by the **Talos native Layer-2 VIP** and an optional **Cilium bootstrap CNI**.

It is the baremetal counterpart to cloud Talos modules: the Talos
secrets/config/bootstrap/kubeconfig core is preserved, while all cloud mechanics
(server creation, `user_data` injection, cloud-API VIP failover, cloud CCM/CSI) are removed.

---

## Architecture

| Concern | Approach |
|---|---|
| **Provisioning** | **Maintenance-mode apply.** Nodes are booted into Talos maintenance mode out-of-band (PXE/USB/ISO — *not* this module's job). `talos_machine_configuration_apply` targets each node's maintenance-mode IP; that apply installs Talos to disk and the node reboots into the configured state. No `talosctl --insecure` shim. |
| **API HA** | **Talos native Layer-2 VIP** (ARP, etcd-elected). The VIP serves the Kubernetes API endpoint only (`https://<vip>:6443`). It is applied inline under `machine.network.interfaces[*].vip` on control planes. |
| **CNI / kube-proxy** | `cluster.network.cni.name = "none"` and `cluster.proxy.disabled = true`. Cilium replaces both. KubePrism is enabled on `:7445` so Cilium reaches the API via `localhost:7445` before the VIP/CNI are up. |
| **Cilium** | Optional **bootstrap** CNI. Rendered locally with `data.helm_template` (template-only — never connects to a cluster) and injected into `cluster.inlineManifests` so Talos applies it at bootstrap. |

### The VIP / bootstrap rule (important)

The native VIP relies on **etcd leader election** and is **not active until AFTER bootstrap**.
Therefore the module uses the VIP **only** as the machine-config API endpoint. Every
operation that must reach a live node — `talos_machine_configuration_apply`,
`talos_machine_bootstrap`, `talos_client_configuration`, `talos_cluster_kubeconfig`,
`talos_cluster_health` — targets a **real control-plane node IP**, never the VIP. The
default target is the first control plane by sort order (`sort(keys(control_planes))[0]`),
overridable with `bootstrap_node`.

### Bring-up graph

```
talos_machine_secrets
  → data.talos_machine_configuration.control_plane / .worker   (cluster_endpoint = https://<vip>:6443)
  → data.talos_client_configuration                            (endpoints/nodes = REAL CP IPs)
  → talos_machine_configuration_apply.control_plane            (node/endpoint = each CP IP, maintenance mode)
  → talos_machine_configuration_apply.worker                   (after control planes)
  → time_sleep.wait_for_boot                                   (install + reboot settle window)
  → talos_machine_bootstrap                                    (first REAL CP IP)
  → data.talos_cluster_health   [optional, post-bootstrap]     (avoids pre-bootstrap etcd deadlock, Talos #7967)
  → talos_cluster_kubeconfig                                   (first REAL CP IP)
```

---

## Prerequisites

1. **Nodes pre-booted into Talos maintenance mode** (out-of-band via PXE/USB/ISO). This
   module does **not** image machines or manage BMC/IPMI/netboot. Each machine must be
   reachable on its IP and answering the Talos API in maintenance mode before `apply`.
2. **All control planes on the SAME Layer-2 subnet.** The native VIP uses gratuitous ARP;
   it cannot cross subnets/routers.
3. **One stable IP per node.** Each node keeps a single management IP — via DHCP
   reservation (by MAC) or static configuration — used **both** in maintenance mode **and**
   after install. That IP is what you put in `control_planes[*].ip` / `workers[*].ip`.
4. **VIP placement.** `control_plane_vip` must sit **inside the control-plane subnet** and
   **outside any DHCP range**, and must not equal any node IP (enforced by a precondition).
5. **Tooling.** OpenTofu `>= 1.8.0`. Providers are resolved automatically (see
   [Requirements](#requirements)). Cilium rendering pulls the chart from `helm.cilium.io`
   on the runner at plan time (no cluster contact).

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

Runnable copies live in [`examples/basic`](examples/basic) and [`examples/ha`](examples/ha).

> Heterogeneous NICs: if a node's VIP interface differs (e.g. `eno1` vs `enp1s0`), set
> it per node with `control_planes["cp-x"].interface`. Leave `vip_interface` unset to use
> a physical-interface `deviceSelector` instead of a fixed name.

---

## Requirements

| Name | Version |
|---|---|
| OpenTofu | `>= 1.8.0` (`>= 1.11` only for the write-only secret-hardening path below) |
| `siderolabs/talos` | `~> 0.11.0` |
| `hashicorp/helm` | `~> 3.0` (template-only; never connects to a cluster) |
| `hashicorp/http` | `~> 3.4` |
| `hashicorp/time` | `~> 0.9` |

Default versions in the examples: Talos `v1.13.5`, Kubernetes `1.36.2`, Cilium chart `1.19.5`.
Confirm the Talos ↔ Kubernetes pairing against the
[Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/).

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
| `deploy_cilium` | `bool` | `true` | Install Cilium as bootstrap CNI. `false` = no CNI (BYO). |
| `cilium_install_method` | `string` | `inline_manifest` | `inline_manifest` or `none`. |
| `cilium_version` | `string` | `1.19.5` | Cilium Helm chart version. |
| `cilium_values` | `any` | `{}` | User Helm values, deep-merged over Talos-tuned defaults. |

### Operations / security

| Name | Type | Default | Description |
|---|---|---|---|
| `apply_mode` | `string` | `auto` | `auto`, `staged`, or `staged_if_needing_reboot`. |
| `enable_health_check` | `bool` | `true` | Run `talos_cluster_health` after bootstrap to gate kubeconfig. |
| `health_check_timeout_seconds` | `number` | `600` | Health check read timeout. |
| `wait_for_boot_seconds` | `number` | `30` | Settle window after CP apply before bootstrap. |
| `labels` | `map(string)` | `{}` | Informational labels surfaced via outputs. |
| `disk_encryption` | `object` | `{ enabled = false }` | Optional LUKS2 system-disk encryption via a KMS endpoint. |

---

## Outputs

| Name | Sensitive | Description |
|---|:---:|---|
| `kubeconfig` | ✅ | Admin kubeconfig (cluster-admin). |
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
| `cilium_deployed` | | Whether Cilium is installed by this module. |

---

## Day-2 operations

- **Avoid surprise reboots.** Set `apply_mode = "staged_if_needing_reboot"` so reboot-only
  changes are staged for the next boot rather than triggering an immediate, live reboot.
- **Adding nodes.** Add a key to `control_planes` (keep the count at 1/3/5) or `workers`
  and re-apply. New nodes must already be in maintenance mode on their target IP. New
  control planes join via Talos discovery after their config is applied.
- **Removing nodes.** Remove the key and apply. `on_destroy` resets the node (wipes Talos)
  and reboots it back to maintenance mode. Removing a control plane shrinks etcd — keep the
  remaining count at 1/3/5 and remove one member at a time. Do **not** remove the
  `bootstrap_node` key while it is still elected; re-point `bootstrap_node` first.
- **Cilium is a *bootstrap* CNI.** It gets pods networking at install time. For production,
  move Cilium's lifecycle to a dedicated GitOps/Helm layer (Argo CD / Flux / `helm_release`)
  and either set `deploy_cilium = false` (BYO from day one) or treat the inline render as a
  one-shot seed that your GitOps layer subsequently owns. Changing `cilium_values` here
  re-renders the inline manifest and re-applies via Talos — fine for bootstrap, not a
  substitute for a real CNI release pipeline.
- **Upgrades.** Talos and Kubernetes version bumps are applied through the same
  config/apply flow; review the Talos upgrade docs and bump `talos_version` /
  `kubernetes_version` deliberately (one minor at a time).

---

## Security

- **Secrets land in state.** `machine_secrets`, `client_configuration`, `talosconfig`, and
  `kubeconfig` are full credentials. They are all marked `sensitive`, but **OpenTofu state
  itself holds them in plaintext.** Use an encrypted remote backend with strict access
  control, or the hardening path below.
- **Hardening path (OpenTofu ≥ 1.11).** Keep PKI out of state by combining:
  - `ephemeral` `talos_machine_secrets` (generated per-run, never persisted), with
  - the **write-only** apply inputs `client_configuration_wo` / `machine_configuration_input_wo`
    (the `_wo` variants are not stored in state), sourcing the secret material from an
    `ephemeral "vault_*"` resource / external KMS.

  This removes long-lived PKI from state at the cost of regenerating ephemeral material each
  run and a higher floor (OpenTofu ≥ 1.11). v1 of this module uses the standard in-state flow
  for broad compatibility; adopt the `_wo` path when your toolchain and secret store support it.
- **No secrets in source.** This module generates all secrets at apply time. Do not commit
  `*.tfvars` containing credentials (the bundled `.gitignore` excludes `*.tfvars`).

---

## Baremetal caveats

- **No compute lifecycle.** Power, firmware, netboot, disk wipe-on-reinstall, and BMC are
  out of scope. If a node is *not* in maintenance mode (e.g. already installed), the initial
  apply will not behave like a fresh install — reset it to maintenance mode first.
- **Single L2 domain for control planes** is mandatory for the VIP. Spanning subnets needs an
  external L4 load balancer instead (not provided here).
- **Disk names are physical.** `/dev/sda` vs `/dev/nvme0n1` vs `/dev/vda` vary by hardware;
  set `install_disk` per node. Wrong disk = wiped data.
- **Static-IP nodes:** set `vip_interface_dhcp = false` and provide addressing via
  `control_planes[*].config_patches` (Talos owns the interface once installed).
- **Cilium chart fetch** happens on the runner; an air-gapped runner needs a mirrored
  `cilium_version` chart (override `repository` via a fork) or `cilium_install_method = "none"`.

---

## Manual end-to-end verification runbook

CI covers `fmt`, `init`, `validate`, and a fully-mocked `tofu test`. A real apply needs
physical nodes in maintenance mode and is therefore **out of CI scope**. To verify against
real hardware:

1. **Image nodes.** Boot every target machine into Talos **maintenance mode** (matching
   `talos_version`) via PXE/USB/ISO. Confirm each answers the Talos API:
   `talosctl -n <node-ip> --insecure version` (the `--insecure` here is talosctl's, used
   only for this out-of-band check — the module itself does not need it).
2. **Reserve addressing.** DHCP-reserve or statically assign each node IP; choose a
   `control_plane_vip` in-subnet and outside DHCP.
3. **Plan.** `tofu plan` and confirm: `cluster_endpoint` is `https://<vip>:6443`; apply /
   bootstrap / kubeconfig target real CP IPs; CNI is `none`; kube-proxy disabled.
4. **Apply.** `tofu apply`. Nodes install Talos and reboot into the configured state; the
   first control plane is bootstrapped; the health gate waits for the API.
5. **Talos health.** `talosctl --talosconfig <(tofu output -raw talosconfig) -n <cp-ip> health`.
6. **Kubernetes.** `tofu output -raw kubeconfig > kubeconfig && KUBECONFIG=kubeconfig kubectl get nodes -o wide` —
   nodes go `Ready` once Cilium is up. `kubectl -n kube-system get pods` shows `cilium*`.
7. **VIP failover (HA).** Confirm the API answers on the VIP
   (`kubectl --server https://<vip>:6443 get --raw=/healthz`), then reboot the elected
   control plane and confirm the VIP migrates and the API stays reachable.
8. **Teardown.** `tofu destroy` resets each node (wipe) and reboots it back to maintenance
   mode, ready for re-provision.
