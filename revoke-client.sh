#!/bin/bash
if [ -z "$1" ]; then
    echo "Uso: $0 <nombre_cliente>"
    exit 1
fi

CLIENT_NAME=$1
CONTAINER_NAME="openvpn-server"
CCD_FILE="/srv/openvpn-data/ccd/$CLIENT_NAME"

echo "Revocando acceso a: $CLIENT_NAME..."
sudo docker exec -it "$CONTAINER_NAME" easyrsa revoke "$CLIENT_NAME"
sudo docker exec -it "$CONTAINER_NAME" easyrsa gen-crl

# Limpieza automática de la IP estática
if [ -f "$CCD_FILE" ]; then
    echo "Eliminando reserva de IP estática..."
    sudo rm -f "$CCD_FILE"
fi

echo "Proceso completado."
