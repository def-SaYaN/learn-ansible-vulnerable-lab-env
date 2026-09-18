# -*- mode: ruby -*-
# vi: set ft=ruby :
# ===========================================================================
#  learn-ansible-vulnerable-lab-env  --  Vagrantfile
#
#  Brings up the isolated lab on a host-only network (10.10.10.0/24). NO VM
#  is bridged to your LAN or the internet except the pivot's NAT interface,
#  which Vagrant needs for box download / apt. Provisioning of the domain
#  and the vulnerabilities is done separately by Ansible (`make deploy`).
#
#  Default provider: virtualbox. libvirt notes are in docs/architecture.md.
# ===========================================================================

Vagrant.require_version ">= 2.2.0"

# --- Boxes (override via env if you mirror your own) -----------------------
WIN_SERVER_BOX = ENV.fetch("LAB_WIN_SERVER_BOX", "gusztavvargadr/windows-server")
WIN_CLIENT_BOX = ENV.fetch("LAB_WIN_CLIENT_BOX", "gusztavvargadr/windows-10")
LINUX_BOX      = ENV.fetch("LAB_LINUX_BOX",      "bento/ubuntu-22.04")

# --- Host definitions (IPs MUST match inventory/hosts.ini) -----------------
NODES = [
  { name: "dc01",  box: WIN_SERVER_BOX, ip: "10.10.10.10", cpus: 2, mem: 2560, os: "windows" },
  { name: "srv01", box: WIN_SERVER_BOX, ip: "10.10.10.20", cpus: 2, mem: 2560, os: "windows" },
  { name: "ws01",  box: WIN_CLIENT_BOX, ip: "10.10.10.30", cpus: 2, mem: 2048, os: "windows" },
  { name: "pivot", box: LINUX_BOX,      ip: "10.10.10.5",  cpus: 1, mem: 1024, os: "linux"   },
]

Vagrant.configure("2") do |config|
  config.vm.boot_timeout = 600

  NODES.each do |node|
    config.vm.define node[:name] do |m|
      m.vm.box      = node[:box]
      m.vm.hostname = node[:name] if node[:os] == "linux"  # Windows hostname set by sysprep/box
      m.vm.network "private_network", ip: node[:ip]

      # ---- Windows: WinRM communicator -------------------------------------
      if node[:os] == "windows"
        m.vm.communicator      = "winrm"
        m.winrm.username       = "vagrant"
        m.winrm.password       = "vagrant"
        m.winrm.transport      = :plaintext          # lab-only; isolated net
        m.winrm.basic_auth_only = true
        m.vm.network "forwarded_port", guest: 5985, host: 55985 + NODES.index(node), id: "winrm", auto_correct: true
        m.vm.network "forwarded_port", guest: 3389, host: 53389 + NODES.index(node), id: "rdp",   auto_correct: true
      else
        # ---- Linux pivot: keeps NAT (eth0) for box/apt + private net --------
        m.vm.network "forwarded_port", guest: 22, host: 52222, id: "ssh", auto_correct: true
      end

      # ---- Provider sizing -------------------------------------------------
      m.vm.provider "virtualbox" do |vb|
        vb.name   = "vulnlab-#{node[:name]}"
        vb.cpus   = node[:cpus]
        vb.memory = node[:mem]
        vb.gui    = false
        vb.customize ["modifyvm", :id, "--groups", "/vulnlab"]
      end

      m.vm.provider "libvirt" do |lv|
        lv.cpus   = node[:cpus]
        lv.memory = node[:mem]
      end
    end
  end

  # NOTE: We deliberately do NOT run Ansible from Vagrant. Bring the VMs up
  # with `vagrant up`, then provision the domain with `make deploy`, so you
  # can re-run / re-plant without recreating VMs. See the Makefile.
end
