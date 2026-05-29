#!/bin/bash

if [ -z "$1" ]; then
    echo "Error: Debes proporcionar el nombre del cliente."
    echo "Uso: $0 <nombre_cliente>"
    exit 1
fi

CLIENT_NAME=$1
CONTAINER_NAME="openvpn-server"
DATA_DIR="/srv/openvpn-data" # Asegúrate de que coincida con tu ruta
CCD_DIR="$DATA_DIR/ccd"

echo "Generando credenciales para: $CLIENT_NAME..."
sudo docker exec -it "$CONTAINER_NAME" easyrsa build-client-full "$CLIENT_NAME" nopass


echo -n "Introduce una IP estática (ej: 192.168.255.50) o deja en blanco para DHCP: "
read STATIC_IP


if [ ! -z "$STATIC_IP" ]; then
    echo "Asignando IP estática: $STATIC_IP al cliente: $CLIENT_NAME"
    sudo mkdir -p "$CCD_DIR"
    # El formato ccd requiere una IP de red y la IP del gateway (ej: 192.168.255.50 192.168.255.49)
    # OpenVPN necesita un par de IPs en el mismo /30 para el túnel
    echo "ifconfig-push $STATIC_IP 192.168.255.49" | sudo tee "$CCD_DIR/$CLIENT_NAME"
    sudo chown $USER:$USER "$CCD_DIR/$CLIENT_NAME"
else
    echo "Cliente configurado para recibir IP dinámica (DHCP)."
    # Limpiamos si existía una configuración previa
    sudo rm -f "$CCD_DIR/$CLIENT_NAME"
fi

echo "Exportando archivo unificado .ovpn..."
sudo docker exec -it "$CONTAINER_NAME" ovpn_getclient "$CLIENT_NAME" > "$HOME/$CLIENT_NAME.ovpn"
sudo chown $USER:$USER "$HOME/$CLIENT_NAME.ovpn"

echo "------------------------------------------------"
echo "Éxito: Archivo listo en $HOME/$CLIENT_NAME.ovpn"
