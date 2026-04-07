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

---

## Inventory

Update `inventory/hosts.yml`. Masters and workers must be children of the `k8s` group:

```yaml
all:
  children:
    k8s:
      children:
        k8smasters:
          hosts:
            k8s-cp1.example.com:
            k8s-cp2.example.com:
            k8s-cp3.example.com:
        k8sworkers:
          hosts:
            k8s-node1.example.com:
            k8s-node2.example.com:
```

---

## Key variables

All variables are in `inventory/group_vars/`:

- `k8s/main.yml` — cluster-wide settings
- `k8smasters/keepalived.yml` — keepalived VIP configuration

| Variable | Default | Description |
|---|---|---|
| `k8s_version` | `1.32` | Kubernetes minor version |
| `k8s_calico_version` | `3.31.0` | Calico CNI version |
| `k8s_init_master` | — | FQDN of node that runs `kubeadm init` — **required** |
| `k8s_control_plane_endpoint` | — | DNS name for the HA API VIP — **required** |
| `k8s_init_token` | — | Bootstrap token — **required for init phase, inject via Vault** |
| `k8s_svc_cidr` | `10.96.0.0/12` | Kubernetes service CIDR |
| `k8s_pod_cidr` | `10.112.0.0/12` | Pod network CIDR |
| `k8s_var_lv` | `lv_var` | LVM logical volume name for `/var` |
| `k8s_var_size` | `256G` | Target size of `/var` LV after extension |

### OIDC

| Variable | Default | Description |
|---|---|---|
| `k8s_oidc_enabled` | `false` | Enable OIDC flags on the API server |
| `k8s_oidc_issuer_url` | `""` | OIDC issuer URL (Keycloak realm URL) |
| `k8s_oidc_client_id` | `kubernetes` | OIDC client ID |
| `k8s_oidc_username_claim` | `preferred_username` | JWT claim for username |
| `k8s_oidc_groups_claim` | `groups` | JWT claim for group membership |

Generate `k8s_init_token` (inject via Vault, do not commit):

```bash
printf '%s.%s\n' "$(tr -dc a-z0-9 </dev/urandom | head -c 6)" \
                 "$(tr -dc a-f0-9 </dev/urandom | head -c 16)"
```

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

---

## Phases

| Phase | Tag | What runs | Runs by default |
|---|---|---|---|
| 1 — Node prep | `config` | Swap disable, kernel, NM, packages, CRI-O, Helm, python3-kubernetes | Yes |
| 1b — LVM | `config` | Extends `/var` LV after swap space is freed | Yes |
| 1c — Keepalived | `config` | Floats k8s-api VIP across control plane nodes | Yes |
| 2 — Init | `init` | `kubeadm init` on `k8s_init_master`, Calico CNI, all nodes join | No (`never`) |
| 3 — Add nodes | `addnodes` | Joins new nodes to an already-initialized cluster | No (`never`) |

---

## File layout

```
deployments/k8s/
  site.yml
  inventory/
    hosts.yml
    group_vars/
      k8s/
        main.yml          # cluster settings, OIDC
      k8smasters/
        keepalived.yml    # VIP, interface, priorities
  collections/
    requirements.yml      # mgcdrd.infrabase, mgcdrd.infrasvc
  README.md
```

---

## Companion deployments

- `deployments/k8s-platform` — day-2 platform bootstrap (MetalLB, Gateway API,
  cert-manager, NFS provisioner, Vault, monitoring, RBAC). Runs after this
  deployment completes the `init` phase.
