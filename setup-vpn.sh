#!/bin/bash

# Salir inmediatamente si un comando falla
set -e

echo "=================================================="
echo " 1. ACTUALIZACIÓN DEL SISTEMA (DEBIAN TRIXIE) "
echo "=================================================="
sudo apt-get update
sudo apt-get full-upgrade -y
sudo apt-get install -y ca-certificates curl gpg

echo "=================================================="
echo " 2. OPTIMIZACIONES DE MEMORIA EN MICRO-INSTANCIA "
echo "=================================================="
if systemctl is-active --quiet google-cloud-ops-agent; then
    echo "Deteniendo Google Cloud Ops Agent para liberar RAM..."
    sudo systemctl stop google-cloud-ops-agent || true
    sudo systemctl disable google-cloud-ops-agent || true
fi

if [ ! -f /swapfile ]; then
    echo "Creando archivo Swap de 1GB..."
    sudo swapoff -a || true
    sudo rm -f /swapfile
    sudo fallocate -l 1G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
fi

if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

echo "=================================================="
echo " 3. INSTALACIÓN IDEMPOTENTE DE DOCKER UPSTREAM "
echo "=================================================="
if ! command -v docker &> /dev/null; then
    echo "Instalando Docker CE..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $USER
else
    echo "Docker ya está instalado. Omitiendo instalación."
fi

echo "=================================================="
echo " 4. LIMPIEZA DE ARTEFACTOS PREVIOS (RESET) "
echo "=================================================="
sudo docker rm -f openvpn-server 2>/dev/null || true
sudo rm -rf /srv/openvpn-data
rm -f "$HOME/laptop.ovpn"
rm -f "$HOME/lenpc.ovpn"

echo "=================================================="
echo " 5. CONFIGURACIÓN E INICIALIZACIÓN DE OPENVPN "
echo "=================================================="
# Obtener la IP pública dinámica de la instancia
JSON_RESPONSE=$(curl -s http://ip-api.com)
PUBLIC_IP=$(echo "$JSON_RESPONSE" | awk -F'"' '/"query"/ {print $4}')

if [ -z "$PUBLIC_IP" ] || [[ ! "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP=$(curl -s ifconfig.me)
fi

PORT="1194"
DATA_DIR="/srv/openvpn-data"
CONTAINER_NAME="openvpn-server"

echo "IP Externa detectada: $PUBLIC_IP"

# Generar la configuración base en modo Split Tunnel (-d deshabilita redirect-gateway)
sudo mkdir -p "$DATA_DIR"
sudo docker run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn ovpn_genconfig -u udp://"$PUBLIC_IP":"$PORT" -d -b

# INYECTAR DIRECTIVAS CRÍTICAS (Subnet moderna, CCD y comunicación entre clientes)
sudo sed -i '/topology/d' "$DATA_DIR/openvpn.conf" # Eliminar duplicados si los hubiera
echo "topology subnet" | sudo tee -a "$DATA_DIR/openvpn.conf"
echo "client-to-client" | sudo tee -a "$DATA_DIR/openvpn.conf"
echo "client-config-dir /etc/openvpn/ccd" | sudo tee -a "$DATA_DIR/openvpn.conf"

# Crear el directorio CCD para las IPs estáticas fijas
sudo mkdir -p "$DATA_DIR/ccd"
echo "ifconfig-push 192.168.255.50 255.255.255.0" | sudo tee "$DATA_DIR/ccd/laptop"
echo "ifconfig-push 192.168.255.60 255.255.255.0" | sudo tee "$DATA_DIR/ccd/lenpc"

echo "Inicializando la infraestructura de Certificados PKI..."
sudo docker run -v "$DATA_DIR:/etc/openvpn" -e "EASYRSA_BATCH=1" -e "EASYRSA_REQ_CN=OpenVPN-GCloud-CA" --rm kylemanna/openvpn ovpn_initpki nopass

echo "Levantando el contenedor de OpenVPN..."
sudo docker run -v "$DATA_DIR:/etc/openvpn" -d \
  -p "$PORT:1194/udp" \
  --cap-add=NET_ADMIN \
  --restart unless-stopped \
  --name "$CONTAINER_NAME" \
  kylemanna/openvpn

echo "Esperando inicialización del core..."
sleep 5

echo "=================================================="
echo " 6. GENERACIÓN AUTOMÁTICA DE PERFILES DE CLIENTE "
echo "=================================================="
# Cliente 1: laptop
sudo docker exec "$CONTAINER_NAME" easyrsa build-client-full "laptop" nopass
sudo docker exec "$CONTAINER_NAME" ovpn_getclient "laptop" > "$HOME/laptop.ovpn"

# Cliente 2: lenpc
sudo docker exec "$CONTAINER_NAME" easyrsa build-client-full "lenpc" nopass
sudo docker exec "$CONTAINER_NAME" ovpn_getclient "lenpc" > "$HOME/lenpc.ovpn"

sudo apt-get clean

echo "=================================================================="
echo " ¡PROCESO DE CONFIGURACIÓN COMPLETADO CORRECTAMENTE!"
echo "=================================================================="
echo " El servidor opera ahora en modo: 'topology subnet' (Estable)"
echo " -> Perfil Portátil (IP Fija .50): $HOME/laptop.ovpn"
echo " -> Perfil Lenovo PC (IP Fija .60): $HOME/lenpc.ovpn"
echo " Ambos perfiles están configurados en Split Tunnel por defecto."
echo "=================================================================="
