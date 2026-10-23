# k8s deployment

Provisions a Kubernetes cluster across Debian and Rocky Linux nodes using
kubeadm. Three-phase site.yml: node preparation, cluster initialization, and
node joins. Keepalived floats a VIP across control plane nodes for HA.

---

## Architecture

```
k8s-cp1.example.com  — control plane + keepalived MASTER ─┐
k8s-cp2.example.com  — control plane + keepalived BACKUP  ─┤─ VIP → k8s-api.example.com
k8s-cp3.example.com  — control plane + keepalived BACKUP  ─┘
k8s-node1.example.com — worker
k8s-node2.example.com — worker
```

Control plane endpoint is a DNS name for the keepalived VIP — all kubeadm
configuration and cert SANs point at it, not individual node IPs.

---

## Prerequisites

- VMs provisioned and reachable via SSH with `become: true`
- DNS record for `k8s_control_plane_endpoint` pointing at the keepalived VIP
- If OIDC is enabled: Keycloak running and the `lab` realm configured before
  running the `init` phase (OIDC flags are baked into kubeadm config)
- Collections installed: `ansible-galaxy collection install -r collections/requirements.yml`
- SELinux is either in Permissive state or disabled
---

## Inventory

Hosts, groups, and all variables come from the environment inventory set in
`ansible.cfg` (`../../inventory-common/lab/hosts.yml`); for another cluster or
environment pass `-i <inventory>/<env>/hosts.yml`:

```
ansible-playbook site.yml
ansible-playbook site.yml --tags init
ansible-playbook site.yml -i ../../../inventory-<client>/prd/hosts.yml
```

One cluster per environment inventory. Nothing else guards against running the
wrong inventory, so check `--list-hosts` first.

The environment's `hosts.yml` lists masters and workers as children of `k8s`:

```yaml
all:
  children:
    k8s:
      children:
        k8smasters:
          hosts:
            k8s-cp1.example.com:
        k8sworkers:
          hosts:
            k8s-node1.example.com:
```

Cluster vars (`k8s_init_master`, `k8s_control_plane_endpoint`, CIDRs, version,
OIDC) live in the inventory's `group_vars/k8s/`, not in this repo.

---

## Variable reference

All variables live in the environment inventory (`inventory-common/lab` for the lab), shared with `deployments/k8s-platform`. Role variables not listed keep the defaults in the [`k8s` role README](../../collections/infrasvc/roles/k8s/README.md).

### Cluster (`group_vars/k8s/k8s.yml`)

| Variable | Default | Required | Description |
|---|---|---|---|
| `k8s_init_master` | none | Yes | FQDN of the node that runs `kubeadm init` |
| `k8s_control_plane_endpoint` | none | Yes | Control plane endpoint DNS name; the keepalived VIP name for HA, or the same as `k8s_init_master` for a single master |
| `k8s_keepalived_enabled` | `false` (role default) | No | `false` for single-master clusters, which skips the keepalived phase entirely |
| `k8s_version` | `1.32` | No | Kubernetes minor version |
| `k8s_calico_version` | `3.31.0` | No | Calico CNI version |
| `k8s_svc_cidr` | `10.96.0.0/12` | No | Kubernetes service CIDR |
| `k8s_pod_cidr` | `10.112.0.0/12` | No | Pod network CIDR |
| `k8s_cluster_group` | `""` | No | Inventory group written to `/etc/hosts`; auto-detected when empty |
| `k8s_init_token` | unset | No | Pins the `kubeadm init` bootstrap token. Unset, kubeadm generates one (4h TTL, used only by `init`; `addnodes` creates its own). Set only to pin a value, injected from Vault |
| `k8s_oidc_enabled` | `false` | No | Enable OIDC flags on the API server |
| `k8s_oidc_issuer_url` | `""` | If `k8s_oidc_enabled` | OIDC issuer URL (Keycloak realm URL) |
| `k8s_oidc_client_id` | `kubernetes` | No | OIDC client ID |
| `k8s_oidc_username_claim` | `preferred_username` | No | JWT claim for the username |
| `k8s_oidc_groups_claim` | `groups` | No | JWT claim for group membership |

### Storage and keepalived (`group_vars/k8s/k8s.yml`, `group_vars/k8smasters/keepalived.yml`)

| Variable | Shipped value | Required | Description |
|---|---|---|---|
| `storage_mounts_extra_k8s` | extends `/var` (`lv_var`) to `256G` (`k8s.yml`) | Yes | LVs extended on all nodes, layered over the base `storage_mounts` for `mgcdrd.infrabase.storage`; the `/var` entry is required for k8s nodes. See **LVM** below |
| `keepalived_vip_for` | `[kubernetes]` (`k8smasters/keepalived.yml`) | No | keepalived preset for the masters |
| `keepalived_vrrp_instances` | `k8s_api`: master `kube1.example.com`, no backups, VIP `192.168.1.10` (`k8smasters/keepalived.yml`) | Yes | VRRP instance for the API VIP; inert while `k8s_keepalived_enabled: false`. Set your own master and VIP |

### LVM

`storage_mounts_extra_k8s` is defined in `group_vars/k8s/k8s.yml`
and layered over the base `storage_mounts` (the CIS mount options from
`group_vars/all/harden.yml`) by `mgcdrd.infrabase.storage`, so those are kept. The default
extends `/var` to 256G. Add entries to extend additional LVs on all nodes, or override in a per-host
or per-group vars file.

```yaml
storage_mounts_extra_k8s:
  - path: /var
    lv: lv_var
    size: 256G
  - path: /data
    lv: lv_data
    size: 500G
```

`size` is a minimum: an LV that is already larger is left alone, and LVs are
never shrunk. `vg` defaults to the VG of the root mount. See the
`mgcdrd.infrabase.storage` role README for the full list of keys.

---

## Usage

```bash
# Phase 1 — node prep, LVM, keepalived (runs by default)
ansible-playbook site.yml

# Phase 2 — cluster initialization (explicit tag required)
ansible-playbook site.yml --tags init

# Phase 3 — join new nodes to existing cluster
ansible-playbook site.yml --tags addnodes
```

The `init` and `addnodes` phases use the `never` tag — they will not run
on a plain `ansible-playbook site.yml` invocation.

If there is a failure during the init run, you might have to reset the kubeadm configs with `kubeadm reset -f`

---

## Phases

| Phase | Tag | What runs | Runs by default |
|---|---|---|---|
| 1 — Node prep | `config` | Swap disable, kernel, NM, packages, CRI-O, Helm, python3-kubernetes | Yes |
| 1b — LVM | `config` | Extends `/var` LV after swap space is freed | Yes |
| 1c — Keepalived | `config` | Floats k8s-api VIP across control plane nodes | Yes (skipped when `k8s_keepalived_enabled: false`) |
| 2 — Init | `init` | `kubeadm init` on `k8s_init_master`, Calico CNI, all nodes join | No (`never`) |
| 3 — Add nodes | `addnodes` | Joins new nodes to an already-initialized cluster | No (`never`) |

---

## File layout

```
deployments/k8s/
  site.yml
  ansible.cfg             # inventory = ../../inventory-common/lab/hosts.yml
  collections/
    requirements.yml      # mgcdrd.infrabase, mgcdrd.infrasvc
  README.md
```

Hosts, groups, and vars (`k8s`, `k8smasters`, `k8sworkers`) live in the
environment inventory.

---

## Companion deployments

- `deployments/k8s-platform` — day-2 platform bootstrap (MetalLB, Gateway API,
  cert-manager, NFS provisioner, Vault, monitoring, RBAC). Runs after this
  deployment completes the `init` phase.
