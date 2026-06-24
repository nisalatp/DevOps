# ☸️ HA Kubernetes Auto-Setup

**Production-Grade HA Kubernetes — Built From Scratch, One Script at a Time**

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36-326CE5?logo=kubernetes&logoColor=white)
![Calico](https://img.shields.io/badge/CNI-Calico_v3.29-EE6B2F)
![Platform](https://img.shields.io/badge/Platform-Vagrant_%7C_Bare_Metal-8B5CF6)

*By [Nisala Aloka Bandara](https://github.com/nisalatp) — An interactive, educational toolkit for building highly-available Kubernetes clusters the right way.*

---

**🧑‍🎓 If you're a beginner** — this project walks you through every stage of setting up Kubernetes, explaining what each command does and why it matters. Every line of every script has detailed comments written for students. You'll understand the infrastructure, not just run it.

**🏗️ If you're a professional** — use this to rapidly spin up disposable HA labs for testing, demos, or training. The scripts work on both Vagrant VMs and bare-metal / cloud servers.

---

## 📖 Table of Contents

1. [What You'll Build](#-what-youll-build)
2. [Architecture](#-architecture)
3. [Prerequisites](#-prerequisites)
4. [Repository Contents](#-repository-contents)
5. [Getting Started](#-getting-started)
6. [Using on Bare Metal / Cloud Servers](#-using-on-bare-metal--cloud-servers)
7. [Topology Reference](#-topology-reference)
8. [Resource Footprint](#-resource-footprint)
9. [Customisation Guide](#-customisation-guide)
10. [Troubleshooting](#-troubleshooting)
11. [FAQ](#-faq)
12. [License](#-license)

---

## 🔭 What You'll Build

By the end of this guide, you'll have a fully working **highly-available (HA) Kubernetes cluster** with:

| Component | What It Does |
|-----------|-------------|
| **2 Load Balancers** | HAProxy instances fronting the API servers, with a Keepalived floating VIP for automatic failover |
| **3 Control Planes** | `kubeadm`-managed nodes running etcd, the API server, controller manager, and scheduler |
| **2 Workers** | Nodes that run your application pods |
| **Calico CNI** | Pod networking with VXLAN encapsulation |
| **containerd** | The container runtime (with `SystemdCgroup` properly configured) |

> **💡 NisalaTP's note:** The default topology is `2 LB + 3 CP + 2 WK`, but you can customise everything — even run `1 LB + 1 CP + 0 WK` on a tight laptop. The `configure.sh` wizard makes this painless.

---

## 🏛 Architecture

```
                     ┌─────────────────────┐
                     │   Your Workstation   │
                     │      (kubectl)       │
                     └──────────┬──────────┘
                                │
                       ┌────────▼────────┐
                       │   VIP: k8s-vip  │   ◄── Floating IP (Keepalived)
                       │  192.168.56.10  │
                       └────────┬────────┘
                     ┌──────────┴──────────┐
                ┌────▼─────┐         ┌─────▼────┐
                │  k8s-lb1 │         │  k8s-lb2 │    ◄── HAProxy
                │  :6443   │         │  :6443   │    (round-robin to CPs)
                └────┬─────┘         └─────┬────┘
                     └──────────┬──────────┘
                                │ :6443
              ┌─────────────────┼─────────────────┐
         ┌────▼────┐      ┌────▼────┐      ┌─────▼───┐
         │ k8s-cp1 │      │ k8s-cp2 │      │ k8s-cp3 │  ◄── Control Planes
         │ (etcd)  │      │ (etcd)  │      │ (etcd)  │  (odd count for quorum)
         └────┬────┘      └────┬────┘      └────┬────┘
              └─────────────────┼────────────────┘
                                │
                  ┌─────────────┴─────────────┐
                  │   Calico Pod Network       │
                  │   10.244.0.0/16 (VXLAN)    │
                  └──────┬──────────────┬──────┘
              ┌──────────▼──┐     ┌─────▼─────────┐
              │   k8s-w1    │     │    k8s-w2     │  ◄── Worker Nodes
              │   (pods)    │     │    (pods)     │  (your workloads)
              └─────────────┘     └───────────────┘
```

> **💡 NisalaTP's note for beginners:** Don't worry if this looks complex — the scripts set up each layer automatically. I just want you to see the big picture of what you're building. In a production Kubernetes cluster, the load balancer layer is critical: if one load balancer fails, the VIP (Virtual IP) floats to the other, so your cluster API stays reachable. That's what "highly available" means.

---

## ✅ Prerequisites

### For Vagrant-based setup (recommended for learning)

| Tool | Minimum Version | Install Guide |
|------|----------------|---------------|
| **VirtualBox** | 7.0+ | [virtualbox.org/wiki/Downloads](https://www.virtualbox.org/wiki/Downloads) |
| **Vagrant** | 2.4+ | [developer.hashicorp.com/vagrant/install](https://developer.hashicorp.com/vagrant/install) |
| **RAM** | 10 GB free | The default 7-VM cluster uses ~10 GB. See [Resource Footprint](#-resource-footprint) for lighter configs. |
| **Disk** | ~5 GB free | Linked clones keep disk usage minimal. |

### For bare-metal / cloud servers

| Requirement | Details |
|-------------|---------|
| **OS** | Debian 12 or Ubuntu 22.04/24.04 (any `apt`-based system with systemd) |
| **Network** | All nodes must be able to reach each other. Port `6443` must be open between LBs and CPs. |
| **curl** | Must be installed on every node |
| **Root / sudo** | The scripts use `sudo` automatically when not running as root |

---

## 📁 Repository Contents

```
HA_AutoSetup/
├── configure.sh            ← Interactive wizard: builds cluster.yaml by asking you questions
├── cluster.yaml            ← Your cluster definition (topology, IPs, VM sizes)
├── Vagrantfile             ← Reads cluster.yaml → creates VMs with hostnames, IPs, /etc/hosts
├── setup-loadbalancer.sh   ← Installs HAProxy + Keepalived VIP on a load balancer node
├── setup-controlplane.sh   ← Installs containerd, kubeadm → inits or joins a control plane
├── setup-worker.sh         ← Installs containerd, kubeadm → joins as a worker node
├── serve.sh                ← Optional: serves scripts over HTTP for air-gapped local networks
├── publish.sh              ← Pushes this repo to your own GitHub
└── .gitignore
```

> **💡 NisalaTP's note:** Each `setup-*.sh` script is **interactive and narrated** — it prints colour-coded stages explaining exactly what it's doing and why. Every single line of every script has detailed comments explaining bash syntax, Kubernetes concepts, and Linux fundamentals. You're not blindly running commands; you're learning infrastructure as you go.

### 🧠 Smart Defaults (Zero-Confusion Setup)

When running on Vagrant, **every script auto-detects its settings** from `cluster.yaml` (which `configure.sh` generated). The scripts:

- **Read all configuration** — VIP, control-plane IPs, Kubernetes version, Pod CIDR, Calico version
- **Identify the node's role** — by matching the VM's hostname (`k8s-lb1`, `k8s-cp1`, etc.) against `cluster.yaml`
- **Auto-decide MASTER vs BACKUP** — the first load balancer (`k8s-lb1`) is automatically the MASTER
- **Auto-decide first vs additional CP** — the first control plane (`k8s-cp1`) automatically runs `kubeadm init`
- **Pre-fill join commands** — saved to `/vagrant/join-commands.txt` (shared across all VMs)

**Result:** Students just press **Enter** through every prompt. No typing IPs, no confusion about roles.

---

## 🚀 Getting Started

### Step 1 — Clone This Repository

```bash
git clone -b K8s https://github.com/nisalatp/DevOps.git
cd DevOps/HA_AutoSetup
```

---

### Step 2 — Configure Your Cluster

Run the interactive configurator. It will ask you a series of questions and generate `cluster.yaml`:

```bash
./configure.sh
```

**What it asks you:**

| Question | Default | What It Means |
|----------|---------|---------------|
| Subnet (first 3 octets) | `192.168.56` | The private network your VMs will live on |
| Number of load balancers | `2` | How many HAProxy instances (2+ enables VIP failover) |
| Number of control planes | `3` | Must be **odd** (1, 3, 5, 7) so etcd can maintain quorum |
| Number of workers | `2` | Nodes that will run your application pods (0–9) |
| VIP host octet | `10` | The floating IP that always points to a healthy load balancer |
| Base box | `bento/debian-12` | The VM image — Debian 12 is the lightest (~120 MB idle RAM) |
| Kubernetes version | `v1.36` | The minor version of Kubernetes to install |
| Pod CIDR | `10.244.0.0/16` | The IP range for pods — **must not overlap** your subnet |
| Per-VM RAM | varies | Memory allocation per role (LB: 512 MB, CP: 2048 MB, WK: 1536 MB) |

> **💡 NisalaTP's tip for beginners:** Just press **Enter** on every question to accept the defaults. That gives you a solid, standard HA cluster. You can always re-run `./configure.sh` later to change things.

> **🏗️ Pro tip:** On a laptop with only 8 GB RAM, try `1 LB + 1 CP + 1 WK` with reduced memory (CP: 1800 MB, WK: 1024 MB). It won't be HA, but it's great for quick experiments.

---

### Step 3 — Create the Virtual Machines

```bash
vagrant up
```

This reads your `cluster.yaml` and creates all the VMs with:
- Correct hostnames (`k8s-lb1`, `k8s-cp1`, etc.)
- Static IPs on a host-only network
- `/etc/hosts` pre-populated so every node can resolve every other node by name
- `curl` pre-installed
- **Descriptive names in VirtualBox** for easy identification:

```
k8s-lb1-LoadBalancer-192.168.56.5
k8s-lb2-LoadBalancer-192.168.56.6
k8s-cp1-ControlPlane-192.168.56.11
k8s-cp2-ControlPlane-192.168.56.12
k8s-cp3-ControlPlane-192.168.56.13
k8s-w1-Worker-192.168.56.21
k8s-w2-Worker-192.168.56.22
```

**⏱ This takes 5–15 minutes** depending on your internet speed (it downloads the base box once, then uses linked clones).

---

### Step 4 — Set Up the Load Balancers

SSH into **each load balancer** and run the load balancer setup script:

```bash
# Terminal 1 — on k8s-lb1:
vagrant ssh k8s-lb1
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-loadbalancer.sh | bash
```

```bash
# Terminal 2 — on k8s-lb2:
vagrant ssh k8s-lb2
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-loadbalancer.sh | bash
```

**What happens inside the script:**

| Stage | What It Does |
|-------|-------------|
| 1 — Gather settings | Auto-detects VIP, control-plane IPs, and MASTER/BACKUP role from `cluster.yaml` and hostname |
| 2 — Install | Installs `haproxy` and `keepalived` via apt |
| 3 — HAProxy config | Adds a TCP frontend on `:6443` that round-robins to your control-plane IPs |
| 4 — Keepalived VIP | Configures the floating VIP with VRRP (one node is MASTER, others are BACKUP) |
| 5 — Verify | Checks that port 6443 is listening and the VIP is assigned |

> **💡 NisalaTP's note:** On Vagrant, the script **auto-detects** whether this node is MASTER or BACKUP from the hostname — `k8s-lb1` (the first LB in `cluster.yaml`) automatically becomes MASTER, all others become BACKUP. Just press **Enter** through all prompts.

> ⚠️ **The backends will show as DOWN** at this point — that's completely normal. The control planes haven't been set up yet, so there's nothing listening on their `:6443`.

---

### Step 5 — Initialise the First Control Plane

This is the most important step. The first control plane bootstraps the entire cluster:

```bash
vagrant ssh k8s-cp1
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash
```

**On Vagrant, the script auto-detects that `k8s-cp1` is the first control plane.** Just press **Enter** through all prompts.

**What happens inside the script:**

| Stage | What It Does |
|-------|-------------|
| 1 — Settings | Auto-detects VIP endpoint, node IP, K8s version, pod CIDR, and Calico version from `cluster.yaml` |
| 2 — Swap | Disables swap (kubelet requires this) |
| 3 — Kernel | Loads `overlay` and `br_netfilter` modules; enables IP forwarding |
| 4 — containerd | Installs and configures containerd with `SystemdCgroup = true` |
| 5 — Kube tools | Adds the official Kubernetes apt repo; installs `kubeadm`, `kubelet`, `kubectl` |
| 6 — Kubelet IP | Pins the kubelet to the correct cluster IP (prevents Vagrant's NAT interface from leaking) |
| 7 — kubeadm init | Runs `kubeadm init` with `--control-plane-endpoint` pointing to the VIP and `--apiserver-cert-extra-sans` for the VIP |
| 8 — Kubeconfig fix | Patches kubeconfig files to use the VIP endpoint (fixes NAT IP leak in `server:` field) |
| 9 — kubectl | Copies the admin kubeconfig to your home directory |
| 10 — Calico | Installs the Tigera operator and creates an IP pool matching your pod CIDR |
| 11 — Join commands | Generates and prints both the **control-plane join** and **worker join** commands |

> **💡 NisalaTP's note:** On Vagrant, the join commands are automatically saved to `/vagrant/join-commands.txt` — a shared folder that all VMs can access. This means when you run the scripts on the other nodes, the join command is **pre-filled** for you. Just press Enter.

---

### Step 6 — Join Additional Control Planes

```bash
# On k8s-cp2:
vagrant ssh k8s-cp2
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash
```

```bash
# On k8s-cp3:
vagrant ssh k8s-cp3
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash
```

**On Vagrant, the script auto-detects that `k8s-cp2`/`k8s-cp3` are NOT the first control plane.** It will default the "Is this the FIRST control plane?" question to **no** and auto-fill the join command from `/vagrant/join-commands.txt`. Just press **Enter** through all prompts.

---

### Step 7 — Join the Workers

```bash
# On k8s-w1:
vagrant ssh k8s-w1
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-worker.sh | bash
```

```bash
# On k8s-w2:
vagrant ssh k8s-w2
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-worker.sh | bash
```

The K8s version and join command are both auto-filled — from `cluster.yaml` and `/vagrant/join-commands.txt` respectively. Press **Enter** through all prompts.

---

### Step 8 — Verify Your Cluster

SSH into any control plane and check:

```bash
vagrant ssh k8s-cp1

# All nodes should show "Ready" (may take 1-2 minutes for Calico to finish)
kubectl get nodes -o wide

# All system pods should be "Running"
kubectl get pods -A
```

**Expected output:**

```
NAME      STATUS   ROLES           AGE   VERSION   INTERNAL-IP      ...
k8s-cp1   Ready    control-plane   10m   v1.36.x   192.168.56.11    ...
k8s-cp2   Ready    control-plane   8m    v1.36.x   192.168.56.12    ...
k8s-cp3   Ready    control-plane   6m    v1.36.x   192.168.56.13    ...
k8s-w1    Ready    <none>          4m    v1.36.x   192.168.56.21    ...
k8s-w2    Ready    <none>          3m    v1.36.x   192.168.56.22    ...
```

🎉 **Congratulations!** You now have a production-grade HA Kubernetes cluster running on your machine.

---

## 🌐 Using on Bare Metal / Cloud Servers

The setup scripts are **not tied to Vagrant** — they work on any Debian/Ubuntu machine. The only difference is that you'll need to provide the join commands manually instead of them being auto-detected.

**On each server, run the appropriate script directly from GitHub:**

```bash
# Load balancers:
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-loadbalancer.sh | bash

# First control plane (answer "yes" to FIRST):
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash

# Additional control planes (answer "no" to FIRST, then paste the join command):
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash

# Workers (paste the worker join command when prompted):
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-worker.sh | bash
```

> **🏗️ Pro tip:** For production bare-metal setups, make sure your servers have DNS entries or `/etc/hosts` entries for each node hostname before running the scripts.

---

## 📐 Topology Reference

### Default Topology (2 + 3 + 2)

| Role | Hostname | Default IP | RAM | vCPUs |
|------|----------|-----------|-----|-------|
| VIP (floating) | `k8s-vip` | `192.168.56.10` | — | — |
| Load Balancer | `k8s-lb1` | `192.168.56.5` | 512 MB | 1 |
| Load Balancer | `k8s-lb2` | `192.168.56.6` | 512 MB | 1 |
| Control Plane | `k8s-cp1` | `192.168.56.11` | 2048 MB | 2 |
| Control Plane | `k8s-cp2` | `192.168.56.12` | 2048 MB | 2 |
| Control Plane | `k8s-cp3` | `192.168.56.13` | 2048 MB | 2 |
| Worker | `k8s-w1` | `192.168.56.21` | 1536 MB | 1 |
| Worker | `k8s-w2` | `192.168.56.22` | 1536 MB | 1 |

### Why Odd Control Planes?

Kubernetes uses **etcd** as its data store, and etcd requires a majority (quorum) to agree on writes:

| Control Planes | Quorum | Can Tolerate Failures |
|:-:|:-:|:-:|
| 1 | 1 | 0 (no HA) |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

With **3 control planes**, you can lose **1 node** and the cluster keeps running. That's why 3 is the recommended minimum for production.

---

## 💻 Resource Footprint

The VMs are tuned to be as light as possible on your machine:

| Optimisation | What It Does |
|-------------|-------------|
| **Minimal base box** | `bento/debian-12` idles at ~120 MB RAM per VM |
| **Linked clones** | All VMs share one base disk image instead of full copies |
| **Trimmed hardware** | 9 MB video RAM, no USB controller, no audio — headless VMs |
| **KVM paravirtualisation** | Better performance for Linux guests on VirtualBox |
| **Right-sized RAM** | Each role gets only what it needs |

### Memory Calculator

| Topology | Calculation | Total VM RAM |
|----------|------------|:------------:|
| 2 LB + 3 CP + 2 WK (default) | 2×512 + 3×2048 + 2×1536 | **~10 GB** |
| 1 LB + 3 CP + 1 WK | 1×512 + 3×2048 + 1×1536 | **~8 GB** |
| 1 LB + 1 CP + 1 WK | 1×512 + 1×2048 + 1×1536 | **~4 GB** |
| 1 LB + 1 CP + 0 WK | 1×512 + 1×2048 | **~2.5 GB** |

> **💡 NisalaTP's tip:** Leave **at least 4 GB free** for your host OS. If you have 16 GB total, the default 10 GB cluster is comfortable. On 8 GB, go with the 4 GB topology.

---

## ⚙️ Customisation Guide

### Change the topology

Re-run `./configure.sh` — it regenerates `cluster.yaml`. Then `vagrant destroy -f && vagrant up` to rebuild.

### Edit cluster.yaml directly

```yaml
# Example: add a third worker
workers:
  - { name: k8s-w1, ip: 192.168.56.21 }
  - { name: k8s-w2, ip: 192.168.56.22 }
  - { name: k8s-w3, ip: 192.168.56.23 }  # add this line
```

### Change the Kubernetes version

Edit the `k8s_version` field in `cluster.yaml`:

```yaml
k8s_version: "v1.36"   # Change to v1.35, v1.34, etc.
```

### Use Ubuntu instead of Debian

```yaml
box: "bento/ubuntu-24.04"   # or "bento/ubuntu-22.04"
```

### Serve scripts locally (air-gapped networks)

If your VMs can't reach GitHub:

```bash
./serve.sh   # Starts a Python HTTP server on port 8000
```

Then use `http://<your-host-ip>:8000/setup-worker.sh` instead of the GitHub URLs.

---

## 🔧 Troubleshooting

### Nodes stuck in "NotReady" status

**Cause:** Calico pods haven't finished starting yet.

```bash
# Check Calico pod status
kubectl get pods -n calico-system

# Wait for all pods to be "Running" (usually takes 1-3 minutes)
watch kubectl get pods -A
```

### kubeadm init fails with "port 6443 already in use"

**Cause:** A previous attempt didn't clean up.

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd $HOME/.kube
```

### Join token expired (after 24 hours)

**Cause:** `kubeadm` tokens expire after 24 hours by default.

```bash
# On any control plane, generate a new token:
kubeadm token create --print-join-command

# For control-plane joins, also upload new certs:
sudo kubeadm init phase upload-certs --upload-certs
```

### VIP not responding

```bash
# On each load balancer, check Keepalived:
sudo systemctl status keepalived
ip addr show eth1 | grep 192.168.56.10

# Check HAProxy:
sudo systemctl status haproxy
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

### Vagrant VMs fail to start

```bash
# Ensure VirtualBox host-only network exists:
VBoxManage list hostonlyifs

# If issues persist, try a clean rebuild:
vagrant destroy -f
vagrant up
```

### Pod CIDR conflict

If you see pods stuck in `ContainerCreating` with network errors, your pod CIDR may overlap with your host network. Re-run `./configure.sh` and choose a different pod CIDR (e.g., `10.245.0.0/16`).

### TLS certificate error: "certificate is valid for X, not Y"

**Cause:** The API server certificate doesn't include the VIP or a NAT interface IP as a Subject Alternative Name (SAN).

This is already handled automatically by the scripts — `setup-controlplane.sh` passes `--apiserver-cert-extra-sans` with the VIP hostname and IP, and pins the kubelet to the correct cluster IP. If you still see this error:

```bash
# Reset and re-run the control-plane setup:
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd $HOME/.kube
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash
```

---

## ❓ FAQ

**Can I use this for production?**

The scripts install production-grade components (kubeadm, containerd, Calico, HAProxy + Keepalived), but for a true production deployment you'd also want: TLS for etcd, node hardening, monitoring (Prometheus), logging (Fluentd/Loki), backup strategy (Velero), and proper DNS. This project is designed primarily as a **learning and lab environment** that mirrors production architecture.

**Why `curl | bash`? Isn't that unsafe?**

For a controlled lab environment, it's convenient and standard practice (Docker, Homebrew, and Rust all use this pattern). The scripts are in this public repo — you can read every line before running them. For production, clone the repo and run the scripts locally instead.

**Can I add nodes after the cluster is built?**

Yes! Generate a new join token on any control plane (`kubeadm token create --print-join-command`) and run the appropriate setup script on the new node.

**Do the scripts work on RHEL / CentOS / Fedora?**

Not yet — they use `apt-get`. Adapting them for `dnf`/`yum` is straightforward (the Kubernetes repo setup is the main change), but it's not currently supported.

**What CNI plugins are supported?**

The scripts install **Calico** with VXLAN encapsulation. If you prefer Flannel, Cilium, or another CNI, skip the Calico stage in the control-plane script and install your preferred CNI manually after `kubeadm init`.

**Can I use this without Vagrant?**

Absolutely. See [Using on Bare Metal / Cloud Servers](#-using-on-bare-metal--cloud-servers). The scripts just need a Debian/Ubuntu machine with `curl` and `sudo` access.

---

## 📄 License

This project is open-source and available under the [MIT License](LICENSE).

---

**Built with ☕ by [Nisala Aloka Bandara (NisalaTP)](https://github.com/nisalatp)** — If this helped you learn Kubernetes, consider giving it a ⭐
