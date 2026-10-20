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

Hosts/groups live in `../../inventory-common/instances/k8s/<name>/hosts.yml`,
one directory per cluster, not in this deployment — clone that repo as a
sibling of `deployments/` (see its README, "Multiple instances"). Pick the
cluster with `DEPLOY_INSTANCE`; `ansible.cfg` builds the inventory path from it:

```
DEPLOY_INSTANCE=lab ansible-playbook site.yml
DEPLOY_INSTANCE=lab ansible-playbook site.yml --tags init
```

Load one instance per run — never two. This deployment no longer runs
`instance_guard`, so an unset or misspelled name is not caught for you.

An instance's `hosts.yml` lists each node in `k8s_<name>` and in its role
group; masters and workers stay children of `k8s`:

```yaml
all:
  children:
    k8s:
      children:
        k8s_example:
          hosts:
            k8s-cp1.example.com:
            k8s-node1.example.com:
        k8smasters:
          hosts:
            k8s-cp1.example.com:
        k8sworkers:
          hosts:
            k8s-node1.example.com:
```

Cluster-specific vars (`k8s_init_master`, `k8s_control_plane_endpoint`, CIDRs,
version, OIDC) live in that instance's `group_vars/k8s_<name>/`, not in this
repo.

---

## Variable reference

Cluster-specific variables live per cluster in `../../inventory-common/instances/k8s/<name>/group_vars/k8s_<name>/` (shared with `deployments/k8s-platform`; see that repo's README, "Multiple instances"). This repo's `inventory/group_vars/` holds only what is the same for every cluster. Role variables not listed keep the defaults in the [`k8s` role README](../../collections/infrasvc/roles/k8s/README.md).

### Per cluster (`inventory-common/instances/k8s/<name>/group_vars/k8s_<name>/`)

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

### Set in this repo (`inventory/group_vars/`)

| Variable | Shipped value | Required | Description |
|---|---|---|---|
| `storage_mounts_extra_k8s` | extends `/var` (`lv_var`) to `256G` (`k8s/main.yml`) | Yes | LVs extended on all nodes, layered over the base `storage_mounts` for `mgcdrd.infrabase.storage`; the `/var` entry is required for k8s nodes. See **LVM** below |
| `keepalived_vip_for` | `[kubernetes]` (`k8smasters/keepalived.yml`) | No | keepalived preset for the masters |
| `keepalived_vrrp_instances` | `k8s_api`: master `kube1.example.com`, no backups, VIP `192.168.1.10` (`k8smasters/keepalived.yml`) | Yes | VRRP instance for the API VIP; inert while `k8s_keepalived_enabled: false`. Set your own master and VIP |

### LVM

`storage_mounts_extra_k8s` is defined in `inventory/group_vars/k8s/main.yml`
and layered over the base `storage_mounts` (the CIS mount options from
inventory-common) by `mgcdrd.infrabase.storage`, so those are kept. The default
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
  inventory/
    group_vars/
      k8s/
        main.yml          # cluster settings, OIDC
      k8smasters/
        keepalived.yml    # VIP, interface, priorities
  collections/
    requirements.yml      # mgcdrd.infrabase, mgcdrd.infrasvc
  README.md
```

Host/group definitions (`k8s`, `k8smasters`, `k8sworkers`) and per-cluster vars
live in `../../inventory-common/instances/k8s/<name>/` instead.

---

## Companion deployments

- `deployments/k8s-platform` — day-2 platform bootstrap (MetalLB, Gateway API,
  cert-manager, NFS provisioner, Vault, monitoring, RBAC). Runs after this
  deployment completes the `init` phase.
