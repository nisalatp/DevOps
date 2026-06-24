# 🛠️ DevOps

**A collection of production-grade automation scripts and tools by [Nisala Aloka Bandara (NisalaTP)](https://github.com/nisalatp).**

Interactive, narrated, and educational — each project walks you through the infrastructure, not just runs it.

---

## 🗂️ Projects by Branch

Each category lives on its own branch for clean, short URLs. Pick a branch to explore:

| Branch | Category | Projects |
|--------|----------|----------|
| [`K8s`](https://github.com/nisalatp/DevOps/tree/K8s) | ☸️ Kubernetes | [HA Auto-Setup](https://github.com/nisalatp/DevOps/tree/K8s/HA_AutoSetup) — Build a production-grade HA cluster from scratch |

> More branches and projects coming soon — Docker, CI/CD, monitoring, and beyond.

---

## 🚀 Quick Start

Each branch has its own `README.md` with detailed instructions. Clone the branch you need:

**Example — HA Kubernetes cluster:**

```bash
git clone -b K8s https://github.com/nisalatp/DevOps.git
cd DevOps/HA_AutoSetup
./configure.sh     # Interactive cluster configurator
vagrant up         # Create the VMs
# Then follow the README to set up each node
```

**Run scripts directly (no clone needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-loadbalancer.sh | bash
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-controlplane.sh | bash
curl -fsSL https://raw.githubusercontent.com/nisalatp/DevOps/K8s/HA_AutoSetup/setup-worker.sh | bash
```

---

## 📄 License

This project is open-source and available under the [MIT License](LICENSE).

---

**Built with ☕ by [Nisala Aloka Bandara (NisalaTP)](https://github.com/nisalatp)**
