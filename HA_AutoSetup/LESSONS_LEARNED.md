# HA Kubernetes on Vagrant — Lessons Learned & Fixes Applied

> **Author:** NisalaTP  
> **Date:** 2026-06-24  
> **Environment:** Kubernetes v1.36.2, kubeadm, VirtualBox 7.x, Vagrant, Ubuntu/Debian  
> **Purpose:** Reference document for updating official course documentation.

---

## Table of Contents

1. [The VirtualBox Dual-NIC Problem](#1-the-virtualbox-dual-nic-problem)
2. [Issue #1 — kubeconfig NAT IP Leak](#issue-1--kubeconfig-nat-ip-leak)
3. [Issue #2 — super-admin.conf (K8s 1.29+)](#issue-2--super-adminconf-k8s-129)
4. [Issue #3 — upload-certs NAT IP Re-detection](#issue-3--upload-certs-nat-ip-re-detection)
5. [Issue #4 — kubernetes-admin RBAC (K8s 1.29+)](#issue-4--kubernetes-admin-rbac-k8s-129)
6. [Issue #5 — API Server Rate Limiting After Calico](#issue-5--api-server-rate-limiting-after-calico)
7. [Issue #6 — GPG Keyring Fails on Script Re-run](#issue-6--gpg-keyring-fails-on-script-re-run)
8. [Issue #7 — VirtualBox VM Naming](#issue-7--virtualbox-vm-naming)
9. [Issue #8 — Ruby Heredoc String Interpolation](#issue-8--ruby-heredoc-string-interpolation)
10. [Summary of All Fixes](#summary-of-all-fixes)
11. [Final Architecture](#final-architecture)

---

## 1. The VirtualBox Dual-NIC Problem

**This is the root cause of Issues #1–#3.** Understanding it is essential.

### The Setup

Every Vagrant VM on VirtualBox gets **two network interfaces**:

| Interface | Type | IP | Purpose |
|-----------|------|-----|---------|
| `eth0` / `enp0s3` | NAT | `10.0.2.15` (always) | Internet access (apt, container pulls) |
| `eth1` / `enp0s8` | Host-Only | `192.168.56.x` (unique) | Cluster communication |

### The Problem

Many tools auto-detect the node's IP by checking the **default route**, which goes through the NAT adapter. This means they pick up `10.0.2.15` — an address that:
- Is **identical** on every VM (VirtualBox reuses it)
- Is **unreachable** from other VMs
- Is **not listed** in the API server's TLS certificate SANs

### Tools Affected

| Tool | What It Does Wrong |
|------|-------------------|
| `kubeadm init` | Writes `server: https://10.0.2.15:6443` into all kubeconfig files |
| `kubelet` | Advertises `10.0.2.15` as its InternalIP if `--node-ip` isn't set |
| `kubeadm init phase upload-certs` | Re-detects `10.0.2.15` and regenerates admin.conf with it |

### The Universal Fix

Always **explicitly tell each tool** which IP to use:

```bash
# For kubelet — systemd drop-in file
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=192.168.56.11"

# For kubeadm init — command-line flag
kubeadm init --apiserver-advertise-address=192.168.56.11

# For kubeadm join — command-line flag
kubeadm join ... --apiserver-advertise-address=192.168.56.12
```

**Auto-detection logic** (used in all our scripts):
```bash
NODE_IP=$(hostname -I | tr ' ' '\n' | grep -vE '^(10\.0\.2\.|127\.|169\.254\.)' | head -1)
```
This filters out NAT (`10.0.2.x`), loopback (`127.x`), and link-local (`169.254.x`), leaving the host-only IP.

---

## Issue #1 — kubeconfig NAT IP Leak

### Severity: **Critical** — Blocks all cluster operations after init

### Error

```
tls: failed to verify certificate: x509: certificate is valid for
10.96.0.1, 192.168.56.11, 192.168.56.10, not 10.0.2.15
```

### When It Occurs

After `kubeadm init`, when running `kubectl` or any tool that reads kubeconfig files.

### Root Cause

`kubeadm init` generates five kubeconfig files in `/etc/kubernetes/`:
- `admin.conf`
- `super-admin.conf` (K8s 1.29+)
- `kubelet.conf`
- `controller-manager.conf`
- `scheduler.conf`

Each file contains a `server:` field. Despite passing `--control-plane-endpoint k8s-vip:6443`, kubeadm writes `server: https://10.0.2.15:6443` into these files because it detects the NAT IP as the node's primary address.

### Fix Applied

**Immediately after `kubeadm init`, patch ALL five kubeconfig files:**

```bash
KUBECONFIG_SERVER="https://k8s-vip:6443"

for cfg in /etc/kubernetes/admin.conf \
           /etc/kubernetes/super-admin.conf \
           /etc/kubernetes/kubelet.conf \
           /etc/kubernetes/controller-manager.conf \
           /etc/kubernetes/scheduler.conf; do
  if [ -f "$cfg" ]; then
    sudo sed -i "s|server:.*|server: $KUBECONFIG_SERVER|g" "$cfg"
  fi
done
```

> **Key lesson:** This must happen BEFORE copying admin.conf to `~/.kube/config`, and BEFORE any kubectl operations (including Calico installation).

---

## Issue #2 — super-admin.conf (K8s 1.29+)

### Severity: **Critical** — Breaks upload-certs even after patching admin.conf

### What Changed in K8s 1.29

kubeadm now creates **two** admin kubeconfig files:

| File | User | Group | Privileges |
|------|------|-------|-----------|
| `admin.conf` | `kubernetes-admin` | `kubeadm:cluster-admins` | Reduced (needs ClusterRoleBinding) |
| `super-admin.conf` | `kubernetes-super-admin` | `system:masters` | Full cluster-admin |

### The Problem

Our initial kubeconfig patch only covered four files (the pre-1.29 set). We missed `super-admin.conf`. Privileged operations like `upload-certs` use `super-admin.conf`, so they were still connecting to `10.0.2.15`.

### Fix Applied

Added `super-admin.conf` to the kubeconfig patch loop (see Issue #1 fix above).

### Lesson

> **Always check the Kubernetes changelog** when targeting a specific version. The admin.conf split was a breaking change in 1.29 that isn't obvious from the kubeadm docs.

---

## Issue #3 — upload-certs NAT IP Re-detection

### Severity: **Critical** — Completely blocks certificate distribution

### Error

```
error: error execution phase upload-certs: could not bootstrap the admin user
in file admin.conf: unable to create ClusterRoleBinding:
Post "https://10.0.2.15:6443/...": tls: failed to verify certificate
```

### Root Cause

Even after patching all kubeconfig files to use `k8s-vip:6443`, `kubeadm init phase upload-certs --upload-certs` **internally re-detects** the node's default-route IP and **regenerates** admin.conf with `10.0.2.15`. This overwrites our patch.

### Evidence

We verified:
- ✅ All five `/etc/kubernetes/*.conf` files → `server: https://k8s-vip:6443`
- ✅ `k8s-vip` resolves to `192.168.56.10`
- ✅ Kubernetes endpoints → `192.168.56.11:6443`
- ✅ API server manifest → `--advertise-address=192.168.56.11`
- ✅ ConfigMap → `controlPlaneEndpoint: k8s-vip:6443`
- ❌ `upload-certs` STILL connects to `10.0.2.15`

**Conclusion:** `10.0.2.15` is not stored anywhere — kubeadm re-detects it at runtime. No amount of kubeconfig patching can fix this.

### Fix Applied

**Eliminated the `upload-certs` call entirely.** Instead:

1. **Capture the `kubeadm init` output** (which already runs `--upload-certs` successfully during init):
   ```bash
   kubeadm init ... --upload-certs 2>&1 | tee /tmp/kubeadm-init-output.log
   ```

2. **Parse the certificate key** from the captured output:
   ```bash
   CKEY=$(grep -oP '(?<=--certificate-key )[a-f0-9]+' /tmp/kubeadm-init-output.log | head -1)
   ```

3. **Copy shared PKI certificates** to `/vagrant/pki/` as a fallback for manual distribution:
   ```bash
   # Only the shared CA and signing keys — node-specific certs are regenerated
   for f in ca.crt ca.key sa.key sa.pub front-proxy-ca.crt front-proxy-ca.key; do
     sudo cp "/etc/kubernetes/pki/$f" "/vagrant/pki/$f"
   done
   for f in ca.crt ca.key; do
     sudo cp "/etc/kubernetes/pki/etcd/$f" "/vagrant/pki/etcd/$f"
   done
   ```

4. **On additional CPs**, pre-install certs before joining (if no `--certificate-key`):
   ```bash
   # Detected automatically by the script
   sudo cp /vagrant/pki/*.* /etc/kubernetes/pki/
   sudo cp /vagrant/pki/etcd/*.* /etc/kubernetes/pki/etcd/
   kubeadm join ... --control-plane  # no --certificate-key needed
   ```

### Lesson

> **`kubeadm init phase upload-certs` is fundamentally broken on multi-NIC VMs.** Don't use it as a standalone command. Either capture the cert key from the original `kubeadm init` output, or use manual certificate distribution.

---

## Issue #4 — kubernetes-admin RBAC (K8s 1.29+)

### Severity: **High** — Blocks additional control planes from joining

### Error

```
error: error execution phase check-etcd: could not retrieve the list of
etcd endpoints: pods is forbidden: User "kubernetes-admin" cannot list
resource "pods" in API group "" in the namespace "kube-system"
```

### When It Occurs

When `kubeadm join --control-plane` runs on additional control planes (cp2, cp3).

### Root Cause

In Kubernetes 1.29+, the `kubernetes-admin` user in `admin.conf` no longer has `cluster-admin` privileges by default. It belongs to the `kubeadm:cluster-admins` group, but the ClusterRoleBinding for that group may not exist or may not be properly created during `kubeadm init`.

When additional CPs join, they generate a local `admin.conf` with the `kubernetes-admin` user and try to check etcd — but the user doesn't have permission to list pods.

### Fix Applied

**On the first CP, after kubectl setup, create the ClusterRoleBinding using `super-admin.conf`:**

```bash
sudo kubectl --kubeconfig /etc/kubernetes/super-admin.conf \
  create clusterrolebinding kubeadm:cluster-admins \
  --clusterrole=cluster-admin \
  --group=kubeadm:cluster-admins
```

This is a one-time operation. Once the binding exists in the cluster, all `kubernetes-admin` users (on any CP) inherit `cluster-admin` through their group membership.

### Lesson

> **K8s 1.29+ requires explicit RBAC for admin.conf.** The `super-admin.conf` is the new "root" — always use it for bootstrapping permissions.

---

## Issue #5 — API Server Rate Limiting After Calico

### Severity: **Medium** — Blocks join command generation

### Error

```
client rate limiter Wait returned an error: rate: Wait(n=1) would
exceed context deadline
```

### When It Occurs

Immediately after installing Calico (the CNI plugin), when trying to run `upload-certs` or `kubeadm token create`.

### Root Cause

Installing Calico creates many Kubernetes resources at once (CustomResourceDefinitions, Deployments, DaemonSets, RBAC rules). The API server becomes temporarily overloaded processing all these objects, and the client-side rate limiter times out.

This is especially pronounced on Vagrant VMs with only 2 GB RAM.

### Fix Applied

**Added a wait/retry loop (Stage 11) between Calico installation and join command extraction:**

```bash
# Wait for API server to stabilize
RETRIES=12
for i in $(seq 1 $RETRIES); do
  if kubectl cluster-info &>/dev/null; then
    break
  fi
  sleep 10
done

# Extra grace period for background processing
sleep 15
```

### Lesson

> **Always add a stabilization wait after installing heavy operators.** The API server is not immediately ready for complex operations after processing many new CRDs.

---

## Issue #6 — GPG Keyring Fails on Script Re-run

### Severity: **Medium** — Blocks re-running setup scripts after `kubeadm reset`

### Error

```
gpg: [fd 0]: OpenPGP data found.
gpg: WARNING: nothing exported
```

(Then `set -e` kills the script.)

### Root Cause

The Kubernetes apt repo setup command:
```bash
curl -fsSL .../Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

If the keyring file already exists (from a previous run), `gpg --dearmor` refuses to overwrite it and exits with an error.

### Fix Applied

**Added `--yes` flag to force overwrite:**

```bash
curl -fsSL .../Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

Applied to both `setup-controlplane.sh` and `setup-worker.sh`.

### Lesson

> **Always design scripts to be idempotent** (safe to re-run). Use `--yes`, `--force`, or pre-delete files when necessary.

---

## Issue #7 — VirtualBox VM Naming

### Severity: **Low** — Cosmetic, but confusing for students

### The Problem

VirtualBox does not support square brackets `[]` in VM names. Our initial format:
```
k8s-cp1 [ControlPlane | 192.168.56.11]
```
...caused Vagrant errors or displayed incorrectly in the VirtualBox Manager.

### Fix Applied

**Switched to dash-separated format:**
```
k8s-cp1-ControlPlane-192.168.56.11
```

In the Vagrantfile:
```ruby
ROLE_LABEL = { 'lb' => 'LoadBalancer', 'cp' => 'ControlPlane', 'wk' => 'Worker' }
vb.name = "#{n['name']}-#{ROLE_LABEL[n['role']]}-#{n['ip']}"
```

### Lesson

> **Only use alphanumeric characters, dashes, dots, and spaces** in VirtualBox VM names. Avoid brackets, pipes, and other special characters.

---

## Issue #8 — Ruby Heredoc String Interpolation

### Severity: **Medium** — Causes Vagrant syntax errors

### Error

```
Vagrantfile:231: syntax error, unexpected ')'
```

### Root Cause

Vagrant's `<<-SHELL` heredoc in Ruby interprets `#{}` as Ruby string interpolation. If bash comments inside the heredoc contain patterns like `#{variable}` or `#(...`, Ruby tries to evaluate them and throws syntax errors.

Example:
```ruby
m.vm.provision 'shell', inline: <<-SHELL
  # This comment about ${variables} causes Ruby to try interpolation
  # And this one about #(functions) causes a syntax error
SHELL
```

### Fix Applied

- Removed `#{}` patterns from bash comments inside `<<-SHELL` blocks
- Used plain English descriptions instead of code-like examples in comments
- Real interpolation like `#{n['name']}` is intentional and kept as-is

### Lesson

> **In Vagrantfile `<<-SHELL` blocks, avoid `#{}` and `#()` in comments.** Ruby processes the heredoc before the shell sees it. Use `<<-'SHELL'` (quoted) to disable interpolation entirely, but then you can't use intentional Ruby interpolation either.

---

## Summary of All Fixes

| # | Issue | Root Cause | Fix | Files Changed |
|---|-------|-----------|-----|--------------|
| 1 | kubeconfig NAT IP leak | kubeadm uses default-route IP | Patch all 5 kubeconfig files post-init | `setup-controlplane.sh` |
| 2 | super-admin.conf missed | New file in K8s 1.29+ | Add to patch loop | `setup-controlplane.sh` |
| 3 | upload-certs re-detects NAT IP | kubeadm regenerates admin.conf internally | Eliminate upload-certs; parse init output + manual cert copy | `setup-controlplane.sh` |
| 4 | kubernetes-admin RBAC | admin.conf reduced privileges in 1.29+ | Create ClusterRoleBinding via super-admin.conf | `setup-controlplane.sh` |
| 5 | API rate limiting after Calico | API server overloaded | Wait/retry loop before join commands | `setup-controlplane.sh` |
| 6 | GPG keyring on re-run | gpg won't overwrite existing file | Add `--yes` flag | `setup-controlplane.sh`, `setup-worker.sh` |
| 7 | VM names with brackets | VirtualBox special char restriction | Use dash-separated format | `Vagrantfile` |
| 8 | Ruby heredoc interpolation | `#{}` in comments → syntax error | Remove interpolation patterns from comments | `Vagrantfile` |

---

## Final Architecture

### Setup Flow (12 Stages on First Control Plane)

```
Stage 1  → Gather settings (auto-detect from cluster.yaml)
Stage 2  → Disable swap
Stage 3  → Load kernel modules (overlay, br_netfilter)
Stage 4  → Install & configure containerd
Stage 5  → Install kubeadm, kubelet, kubectl
Stage 6  → Pin kubelet to cluster IP (prevents NAT leak)
Stage 7  → kubeadm init (capture output for join commands)
Stage 8  → Patch ALL kubeconfig files (admin, super-admin, kubelet, etc.)
Stage 9  → Configure kubectl + grant cluster-admin RBAC
Stage 10 → Install Calico CNI
Stage 11 → Wait for API server to stabilize
Stage 12 → Extract join commands + copy PKI certs to /vagrant
```

### Certificate Distribution (Vagrant)

```
┌──────────────────────┐      /vagrant/pki/        ┌──────────────────────┐
│   k8s-cp1 (first)    │ ──── ca.crt, ca.key ────▶ │  k8s-cp2, k8s-cp3    │
│                      │      sa.key, sa.pub        │  (additional CPs)    │
│  kubeadm init        │      front-proxy-ca.*      │                      │
│  --upload-certs      │      etcd/ca.*             │  Pre-install PKI     │
│                      │                            │  → kubeadm join      │
│  Saves init output   │      /vagrant/             │    --control-plane   │
│  → parse cert key    │ ──── join-commands.txt ──▶ │    (no cert key OK)  │
└──────────────────────┘                            └──────────────────────┘
```

### Key Takeaway

> **VirtualBox's NAT adapter is the #1 enemy of kubeadm on Vagrant.** Every tool that auto-detects the node IP will pick `10.0.2.15`. The fix is always the same: explicitly pass the correct IP via flags, drop-in files, or post-init patches. And in K8s 1.29+, you also need to handle the admin.conf privilege reduction and the new super-admin.conf file.
