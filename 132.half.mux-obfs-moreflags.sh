#!/bin/bash
set -e

INSTALL_DIR="/root/packettunnel"
SERVICE_FILE="/etc/systemd/system/packettunnel.service"
CORE_URL="https://raw.githubusercontent.com/NIKA1371/pakat-old/main/core.json"
WATERWALL_URL="https://raw.githubusercontent.com/NIKA1371/pakat-old/main/Waterwall"

################################
# UNINSTALL
################################
if [[ "$1" == "--uninstall" ]]; then
    systemctl stop packettunnel.service 2>/dev/null || true
    systemctl disable packettunnel.service 2>/dev/null || true
    pkill -f Waterwall 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f /etc/systemd/system/packettunnel*
    systemctl daemon-reexec
    systemctl daemon-reload
    echo "Removed."
    exit 0
fi

################################
# PARSE ARGS
################################
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
                PORTS+=("$1")
                shift || break
            done ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done

[[ -z "$ROLE" || -z "$IP_IRAN" || -z "$IP_KHAREJ" ]] && {
    echo "Missing args"; exit 1;
}

################################
# PREPARE
################################
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

curl -fsSL "$WATERWALL_URL" -o Waterwall
chmod +x Waterwall
curl -fsSL "$CORE_URL" -o core.json

################################
# CONFIG GENERATOR
################################
gen_config() {
local SRC_IP="$1"
local DST_IP="$2"
local RAW_IP="$3"
local MODE="$4"

cat > config.json <<EOF
{
  "name": "$MODE",
  "nodes": [
    { "name": "tun", "type": "TunDevice",
      "settings": { "device-name": "wtun0", "device-ip": "10.10.0.1/24" },
      "next": "srcip" },

    { "name": "srcip", "type": "IpOverrider",
      "settings": { "direction": "up", "mode": "source-ip", "ipv4": "$SRC_IP" },
      "next": "dstip" },

    { "name": "dstip", "type": "IpOverrider",
      "settings": { "direction": "up", "mode": "dest-ip", "ipv4": "$DST_IP" },
      "next": "manip1" },

    { "name": "manip1", "type": "IpManipulator",
      "settings": { "protoswap": 253 },
      "next": "manip2" },

    { "name": "manip2", "type": "IpManipulator",
      "settings": {
        "up-tcp-bit-ack": "packet->fin",
        "up-tcp-bit-fin": "packet->ack",
        "dw-tcp-bit-fin": "packet->ack",
        "dw-tcp-bit-ack": "packet->fin"
      },
      "next": "dnsrc" },

    { "name": "dnsrc", "type": "IpOverrider",
      "settings": { "direction": "down", "mode": "source-ip", "ipv4": "10.10.0.2" },
      "next": "dndst" },

    { "name": "dndst", "type": "IpOverrider",
      "settings": { "direction": "down", "mode": "dest-ip", "ipv4": "10.10.0.1" },
      "next": "stream" },

    { "name": "stream", "type": "RawSocket",
      "settings": { "capture-filter-mode": "source-ip", "capture-ip": "$RAW_IP" } },
EOF

base_port=30083
skip_port=30087

for i in "${!PORTS[@]}"; do
  while [[ $base_port -eq $skip_port ]]; do ((base_port++)); done

  if [[ "$MODE" == "iran" ]]; then
cat >> config.json <<EOF
    { "name": "in$((i+1))", "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": ${PORTS[$i]}, "nodelay": true },
      "next": "hd$((i+1))" },

    { "name": "hd$((i+1))", "type": "HalfDuplexClient", "settings": {},
      "next": "obfs$((i+1))" },

    { "name": "obfs$((i+1))", "type": "ObfuscatorClient",
      "settings": { "method": "xor", "xor_key": 123 },
      "next": "mux$((i+1))" },

    { "name": "mux$((i+1))", "type": "MuxClient",
      "settings": { "mode": "counter", "connection-capacity": 8 },
      "next": "out$((i+1))" },

    { "name": "out$((i+1))", "type": "TcpConnector",
      "settings": { "address": "10.10.0.2", "port": $base_port, "nodelay": true } },
EOF
  else
cat >> config.json <<EOF
    { "name": "in$((i+1))", "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": $base_port, "nodelay": true },
      "next": "mux$((i+1))" },

    { "name": "mux$((i+1))", "type": "MuxServer", "settings": {},
      "next": "hd$((i+1))" },

    { "name": "hd$((i+1))", "type": "HalfDuplexServer", "settings": {},
      "next": "obfs$((i+1))" },

    { "name": "obfs$((i+1))", "type": "ObfuscatorServer",
      "settings": { "method": "xor", "xor_key": 123 },
      "next": "out$((i+1))" },

    { "name": "out$((i+1))", "type": "TcpConnector",
      "settings": { "address": "127.0.0.1", "port": ${PORTS[$i]}, "nodelay": true } },
EOF
  fi
  ((base_port++))
done

sed -i '$ s/,$//' config.json
echo "  ] }" >> config.json
}

################################
# BUILD CONFIG
################################
if [[ "$ROLE" == "iran" ]]; then
    gen_config "$IP_IRAN" "$IP_KHAREJ" "$IP_KHAREJ" iran
else
    gen_config "$IP_KHAREJ" "$IP_IRAN" "$IP_IRAN" kharej
fi

################################
# POSTSTART
################################
cat > poststart.sh <<'EOF'
#!/bin/bash
for i in {1..6}; do
  ip link show wtun0 && break
  sleep 1
done
ip link set wtun0 up || true
ip link set wtun0 mtu 1420 || true
ip link set eth0 mtu 1420 || true
EOF
chmod +x poststart.sh

################################
# SYSTEMD
################################
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PacketTunnel
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/bash -c "ip link delete wtun0 2>/dev/null || true"
ExecStart=/bin/bash -c "$INSTALL_DIR/Waterwall"
ExecStartPost=$INSTALL_DIR/poststart.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now packettunnel.service

echo "PacketTunnel running."
