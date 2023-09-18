#!/bin/bash

# Copyright (c) 2023 Intel Corporation.
# All rights reserved.

set -Eeuo pipefail
trap 'echo "Error line ${LINENO}: $BASH_COMMAND"' ERR

# Update /etc/libvirt/qemu.conf

UPDATE_FILE="/etc/libvirt/qemu.conf"
UPDATE_LINE="security_default_confined = 0"
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s/^#security_default_confined.*/$UPDATE_LINE/g" $UPDATE_FILE
fi

UPDATE_LINE='user = "root"'
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s/^#user.*/$UPDATE_LINE/g" $UPDATE_FILE
fi

UPDATE_LINE='group = "root"'
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s/^#group.*/$UPDATE_LINE/g" $UPDATE_FILE
fi

UPDATE_LINE='cgroup_device_acl = ['
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s/^#cgroup_device_acl.*/$UPDATE_LINE/g" $UPDATE_FILE
fi

UPDATE_LINE='    "/dev/null", "/dev/full", "/dev/zero",'
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s+#    \"/dev/null\".*+$UPDATE_LINE+g" $UPDATE_FILE
fi

UPDATE_LINE='    "/dev/random", "/dev/urandom",'
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s+#    \"/dev/random\".*+$UPDATE_LINE+g" $UPDATE_FILE
fi

UPDATE_LINE='    "/dev/ptmx", "/dev/kvm", "/dev/udmabuf", "/dev/dri/card0"]'
if [[ "$UPDATE_LINE" != $(sudo cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  sudo sed -i "s+#    \"/dev/ptmx\".*+$UPDATE_LINE+g" $UPDATE_FILE
fi

# Update /etc/sysctl.conf

UPDATE_FILE="/etc/sysctl.conf"
UPDATE_LINE="net.bridge.bridge-nf-call-iptables=0"
if [[ "$UPDATE_LINE" != $(cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  echo $UPDATE_LINE | sudo tee -a $UPDATE_FILE
  sudo sysctl $UPDATE_LINE
fi

UPDATE_LINE="net.ipv4.conf.all.route_localnet=1"
if [[ "$UPDATE_LINE" != $(cat $UPDATE_FILE | grep -F "$UPDATE_LINE") ]]; then
  echo $UPDATE_LINE | sudo tee -a $UPDATE_FILE
  sudo sysctl $UPDATE_LINE
fi

# Update default network dhcp host

tee default_network.xml &>/dev/null <<EOF
<network>
  <name>default</name>
  <bridge name='virbr0'/>
  <forward/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
      <host mac='52:54:00:ab:cd:11' name='ubuntu' ip='192.168.122.11'/>
      <host mac='52:54:00:ab:cd:22' name='windows' ip='192.168.122.22'/>
      <host mac='52:54:00:ab:cd:33' name='android' ip='192.168.122.33'/>
      <host mac='52:54:00:ab:cd:44' name='ubuntu_rt' ip='192.168.122.44'/>
    </dhcp>
  </ip>
</network>
EOF

echo end of file

if [ ! -z $(sudo virsh net-list --name | grep default) ]; then
    sudo virsh net-destroy default
fi
if [ ! -z $(sudo virsh net-list --name --all | grep default) ]; then
    sudo virsh net-undefine default
fi
sudo virsh net-define default_network.xml
sudo virsh net-autostart default
sudo virsh net-start default


# a hook-helper for libvirt which allows easier per-VM hooks.
# usually /etc/libvirt/libvirt/hooks/qemu.d/vm_name/hook_name/state_name/
# See: https://passthroughpo.st/simple-per-vm-libvirt-hooks-with-the-vfio-tools-hook-helper/
wget 'https://raw.githubusercontent.com/PassthroughPOST/VFIO-Tools/master/libvirt_hooks/qemu' -O qemu

# Create qemu hook for port forwarding from host to VMs
tee -a qemu &>/dev/null <<EOF

if [ "\${1}" = "ubuntu" ]; then
 
  # Update the following variables to fit your setup
  GUEST_IP=192.168.122.11
  GUEST_PORT=22
  HOST_PORT=1111
 
  if [ "\${2}" = "stopped" ] || [ "\${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
    /sbin/iptables -t nat -D PREROUTING -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -D OUTPUT -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -D POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
  fi
  if [ "\${2}" = "start" ] || [ "\${2}" = "reconnect" ]; then
    /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
    /sbin/iptables -t nat -I PREROUTING -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -I OUTPUT -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -I POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
  fi

elif [ "\${1}" = "windows" ]; then
 
  # Update the following variables to fit your setup
  GUEST_IP=192.168.122.22
  declare -A HOST_PORTS
  HOST_PORTS=([22]=2222 [3389]=3389)
 
  for GUEST_PORT in "\${!HOST_PORTS[@]}"; do
    if [ "\${2}" = "stopped" ] || [ "\${2}" = "reconnect" ]; then
      /sbin/iptables -D FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
      /sbin/iptables -t nat -D PREROUTING -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -D OUTPUT -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -D POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
    fi
    if [ "\${2}" = "start" ] || [ "\${2}" = "reconnect" ]; then
      /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
      /sbin/iptables -t nat -I PREROUTING -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -I OUTPUT -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -I POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
    fi
  done

elif [ "\${1}" = "android" ]; then

  # Update the following variables to fit your setup
  GUEST_IP=192.168.122.33
  declare -A HOST_PORTS
  HOST_PORTS=([22]=3333 [5554]=5554 [5555]=5555)

  for GUEST_PORT in "\${!HOST_PORTS[@]}"; do
    if [ "\${2}" = "stopped" ] || [ "\${2}" = "reconnect" ]; then
      /sbin/iptables -D FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
      /sbin/iptables -t nat -D PREROUTING -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -D OUTPUT -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -D POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
    fi
    if [ "\${2}" = "start" ] || [ "\${2}" = "reconnect" ]; then
      /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
      /sbin/iptables -t nat -I PREROUTING -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -I OUTPUT -p tcp --dport \${HOST_PORTS[\$GUEST_PORT]} -j DNAT --to \$GUEST_IP:\$GUEST_PORT
      /sbin/iptables -t nat -I POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
    fi
  done

elif [ "\${1}" = "ubuntu_rt" ]; then

  # Update the following variables to fit your setup
  GUEST_IP=192.168.122.44
  GUEST_PORT=22
  HOST_PORT=4444

  if [ "\${2}" = "stopped" ] || [ "\${2}" = "reconnect" ]; then
    /sbin/iptables -D FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
    /sbin/iptables -t nat -D PREROUTING -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -D OUTPUT -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -D POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
  fi
  if [ "\${2}" = "start" ] || [ "\${2}" = "reconnect" ]; then
    /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j ACCEPT
    /sbin/iptables -t nat -I PREROUTING -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -I OUTPUT -p tcp --dport \$HOST_PORT -j DNAT --to \$GUEST_IP:\$GUEST_PORT
    /sbin/iptables -t nat -I POSTROUTING -p tcp -d \$GUEST_IP --dport \$GUEST_PORT -j MASQUERADE
  fi

fi
EOF

sudo mv qemu /etc/libvirt/hooks/qemu
sudo chmod +x /etc/libvirt/hooks/qemu
sudo mkdir -p /etc/libvirt/hooks/qemu.d

sudo systemctl restart libvirtd

# install dependencies
sudo apt install -y virt-manager

# Add user running host setup to group libvirt
username=""
if [[ -z ${SUDO_USER+x} || -z $SUDO_USER ]]; then
    echo "Add $USER to group libvirt."
	username=$USER
else
    echo "Add $SUDO_USER to group libvirt."
	username=$SUDO_USER
fi
if [[ ! -z $username ]]; then
	sudo usermod -a -G libvirt $username
fi

# Allow ipv4 forwarding for host/vm ssh
sudo sed -i "s/\#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g" /etc/sysctl.conf
sudo sysctl -p

# Temporary workaround: not require password sudo for launch_multios.sh until sriov dep are
# taken care not in launch_multios.sh
script=$(realpath "${BASH_SOURCE[0]}")
scriptpath=$(dirname "$script")
platpaths=( $(find "$scriptpath/../../platform/" -maxdepth 1 -mindepth 1 -type d) )
for p in "${platpaths[@]}"; do
    platscript=$(find "$p" -maxdepth 1 -mindepth 1 -type f -name "launch_multios.sh")
    platscript=$(realpath "$platscript")
	if ! grep -Fqs "$platscript" /etc/sudoers.d/multios-sudo; then
		sudo tee -a /etc/sudoers.d/multios-sudo &>/dev/null <<EOF
%libvirt ALL=(ALL) NOPASSWD:SETENV:$platscript
EOF
	fi
done
sudo chmod 440 /etc/sudoers.d/multios-sudo
