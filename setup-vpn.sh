#!/bin/bash

# Exit on any failure
set -e

# --- 1. System Prep ---
sudo apt-get update
sudo apt-get full-upgrade -y
sudo apt-get install -y ca-certificates curl gpg iptables-persistent

# --- 2. Memory Optimizations ---
if systemctl is-active --quiet google-cloud-ops-agent; then
    sudo systemctl stop google-cloud-ops-agent && sudo systemctl disable google-cloud-ops-agent
fi

if [ ! -f /swapfile ]; then
    sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile
    sudo mkswap /swapfile && sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# --- 3. Install Docker ---
if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
    sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo usermod -aG docker $USER
fi

# --- 4. Network Configuration (Persistent) ---
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-openvpn.conf
sudo sysctl -p /etc/sysctl.d/99-openvpn.conf

# Interface detection (usually ens4 on GCloud)
IFACE=$(ip route | grep default | awk '{print $5}')
sudo iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o "$IFACE" -j MASQUERADE
sudo iptables -A FORWARD -i tun0 -o "$IFACE" -j ACCEPT
sudo iptables -A FORWARD -i "$IFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo sh -c "iptables-save > /etc/iptables/rules.v4"

# --- 5. OpenVPN Configuration ---
DATA_DIR="/srv/openvpn-data"
PUBLIC_IP=$(curl -s ifconfig.me)
PORT="1194"

sudo rm -rf "$DATA_DIR"
sudo mkdir -p "$DATA_DIR"

# Generate Config
sudo docker run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn ovpn_genconfig -u udp://"$PUBLIC_IP":"$PORT"
echo 'push "redirect-gateway def1 bypass-dhcp"' | sudo tee -a "$DATA_DIR/openvpn.conf"
echo 'push "dhcp-option DNS 8.8.8.8"' | sudo tee -a "$DATA_DIR/openvpn.conf"
echo "client-to-client" | sudo tee -a "$DATA_DIR/openvpn.conf"

# Initialize PKI & Start
sudo docker run -v "$DATA_DIR:/etc/openvpn" -e "EASYRSA_BATCH=1" -e "EASYRSA_REQ_CN=OpenVPN-CA" --rm kylemanna/openvpn ovpn_initpki nopass
sudo docker run -v "$DATA_DIR:/etc/openvpn" -d -p "$PORT:1194/udp" --cap-add=NET_ADMIN --restart unless-stopped --name openvpn-server kylemanna/openvpn

# --- 6. Client Generation ---
sleep 5
sudo docker exec openvpn-server easyrsa build-client-full laptop nopass
sudo docker exec openvpn-server ovpn_getclient laptop > "$HOME/laptop.ovpn"

echo "Setup complete. Download $HOME/laptop.ovpn to your client."
