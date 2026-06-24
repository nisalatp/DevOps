# Vagrantfile — builds the VMs described in cluster.yaml.
# It does NOT install Kubernetes; that is done by the interactive
# setup-*.sh scripts so you can watch and learn each stage.
#
# Footprint optimisations for running ~7 VMs at once:
#   * a minimal base box (see cluster.yaml: box)
#   * VirtualBox linked clones  -> the VMs share ONE base disk image
#   * trimmed virtual hardware  -> tiny video RAM, no USB, KVM paravirt
#   * right-sized RAM per role  -> see cluster.yaml: resources
require 'yaml'

cfg = YAML.load_file(File.join(__dir__, 'cluster.yaml'))
res = cfg['resources'] || {}
DEF_MEM = { 'lb' => 512,  'cp' => 2048, 'wk' => 1536 }
DEF_CPU = { 'lb' => 1,    'cp' => 2,    'wk' => 1 }

nodes = []
{ 'lb' => 'load_balancers', 'cp' => 'control_planes', 'wk' => 'workers' }.each do |role, group|
  (cfg[group] || []).each do |n|
    mem  = (res[role] && res[role]['memory']) || DEF_MEM[role]
    cpus = (res[role] && res[role]['cpus'])   || DEF_CPU[role]
    nodes << n.merge('role' => role, 'mem' => mem, 'cpus' => cpus)
  end
end

# /etc/hosts content shared by every machine (all nodes + the VIP name).
hosts = nodes.map { |n| "#{n['ip']} #{n['name']}" }.join("\n")
hosts += "\n#{cfg['vip']} k8s-vip"

Vagrant.configure('2') do |config|
  config.vm.box = cfg['box']
  config.vm.boot_timeout = 600

  nodes.each do |n|
    config.vm.define n['name'] do |m|
      m.vm.hostname = n['name']
      m.vm.network 'private_network', ip: n['ip']

      m.vm.provider 'virtualbox' do |vb|
        vb.name         = n['name']
        vb.memory       = n['mem']
        vb.cpus         = n['cpus']
        vb.linked_clone = true                                   # share the base disk
        vb.customize ['modifyvm', :id, '--vram', '9']            # minimal video RAM (headless)
        vb.customize ['modifyvm', :id, '--paravirtprovider', 'kvm']  # faster Linux guest
        vb.customize ['modifyvm', :id, '--usb', 'off']           # drop unneeded controllers
        vb.customize ['modifyvm', :id, '--audio-driver', 'none']
      end

      # Base config only: hostnames resolvable + curl present.
      m.vm.provision 'shell', inline: <<-SHELL
        set -e
        if ! grep -q 'k8s-vip' /etc/hosts; then
          cat >> /etc/hosts <<'EOF'
#{hosts}
EOF
        fi
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y  >/dev/null 2>&1 || true
        apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
        echo "[#{n['name']}] ready (role=#{n['role']}, #{n['mem']}MB/#{n['cpus']}cpu, ip=#{n['ip']})."
      SHELL
    end
  end
end
