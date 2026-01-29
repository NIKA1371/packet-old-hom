#!/bin/bash
set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/NIKA1371/packet-old-hom/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/NIKA1371/packet-old-hom/main/Waterwall"

ROLE=""
IP_IRAN=""
IP_KHAREJ=""
PORTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --ip-iran) IP_IRAN="$2"; shift 2 ;;
    --ip-kharej) IP_KHAREJ="$2"; shift 2 ;;
    --ports)
      shift
      while [[ "$1" =~ ^[0-9]+$ ]]; do
        PORTS+=("$1"); shift
      done ;;
    *) echo "Unknown arg $1"; exit 1 ;;
  esac
done

mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

curl -fsSL $WATERWALL_URL -o Waterwall
chmod +x Waterwall

############################
# CONFIG
############################

if [[ "$ROLE" == "iran" ]]; then
cat > config.json <<EOF
{
  "name": "iran",
  "nodes": [
    { "name":"tun","type":"TunDevice","settings":{"device-name":"wtun0","device-ip":"10.10.0.1/24"},"next":"ipov1"},
    { "name":"ipov1","type":"IpOverrider","settings":{"direction":"up","mode":"source-ip","ipv4":"$IP_IRAN"},"next":"ipov2"},
    { "name":"ipov2","type":"IpOverrider","settings":{"direction":"up","mode":"dest-ip","ipv4":"$IP_KHAREJ"},"next":"manip"},
    { "name":"manip","type":"IpManipulator","settings":{
        "up-tcp-bit-ack":"packet->fin",
        "up-tcp-bit-fin":"packet->ack",
        "dw-tcp-bit-ack":"packet->fin",
        "dw-tcp-bit-fin":"packet->ack"
    },"next":"ipov3"},
    { "name":"ipov3","type":"IpOverrider","settings":{"direction":"down","mode":"source-ip","ipv4":"10.10.0.2"},"next":"ipov4"},
    { "name":"ipov4","type":"IpOverrider","settings":{"direction":"down","mode":"dest-ip","ipv4":"10.10.0.1"},"next":"raw"},
    { "name":"raw","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"$IP_KHAREJ"},"next":"pad"},
    { "name":"pad","type":"PacketAsData","next":"out"},
EOF

for i in "${!PORTS[@]}"; do
cat >> config.json <<EOF
    { "name":"out$i","type":"TcpConnector","settings":{"address":"$IP_KHAREJ","port":${PORTS[$i]},"nodelay":true} }$( [[ $i -lt $((${#PORTS[@]}-1)) ]] && echo , )
EOF
done

echo "  ]}" >> config.json
fi

############################
# SERVICE
############################

cat > $SERVICE_FILE <<EOF
[Unit]
After=network.target
[Service]
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/bash -c "ip link delete wtun0 || true"
ExecStart=$INSTALL_DIR/Waterwall
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now packettunnel
