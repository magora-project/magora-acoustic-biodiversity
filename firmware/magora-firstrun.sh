#!/bin/bash
# Magora Network — First Run Provisioning
# Runs once on first boot, reads magora-config.json from bootfs and self-provisions the node

set -e

CONFIG="/boot/firmware/magora-config.json"
STATUS_FILE="/boot/firmware/magora-status.txt"
COMPLETE_FLAG="/var/lib/magora-firstrun-complete"
LOG="/var/log/magora-firstrun.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "$LOG" 2>/dev/null || true
  echo "$msg" >> "$STATUS_FILE" 2>/dev/null || true
}

log "=== Magora Firstrun Starting ==="

# Wait for config file (up to 2 minutes)
for i in $(seq 1 24); do
  [ -f "$CONFIG" ] && break
  log "Waiting for magora-config.json ($i/24)..."
  sleep 5
done

if [ ! -f "$CONFIG" ]; then
  log "ERROR: magora-config.json not found on bootfs. Cannot provision."
  exit 1
fi

log "Config found. Parsing..."

read_config() {
  python3 -c "import json; d=json.load(open('$CONFIG')); print(d.get('$1',''))"
}

NODE_ID=$(read_config node_id)
NODE_NAME=$(read_config node_name)
NODE_EMAIL=$(read_config node_email)
NODE_PASSWORD=$(read_config node_password)
SUPABASE_URL=$(read_config supabase_url)
SUPABASE_ANON_KEY=$(read_config supabase_anon_key)
LAT=$(read_config lat)
LON=$(read_config lon)
WIFI_SSID=$(read_config wifi_ssid)
WIFI_PASSWORD=$(read_config wifi_password)

log "Node: $NODE_NAME"

# Configure WiFi
log "Configuring WiFi ($WIFI_SSID)..."
nmcli radio wifi on || true
nmcli connection delete magora-wifi 2>/dev/null || true
nmcli connection add type wifi ifname wlan0 con-name magora-wifi \
  ssid "$WIFI_SSID" \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk "$WIFI_PASSWORD" \
  connection.autoconnect yes \
  ipv4.method auto
nmcli connection up magora-wifi || true

# Wait for network
log "Waiting for network..."
for i in $(seq 1 30); do
  ping -c1 -W2 8.8.8.8 &>/dev/null && { log "Network up."; break; }
  sleep 2
done

if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
  log "ERROR: No network after 60s. Check WiFi credentials in magora-config.json."
  exit 1
fi

# Set up magora service user
log "Setting up magora user..."
useradd -r -s /bin/bash -d /home/magora magora 2>/dev/null || true
mkdir -p /home/magora
usermod -aG audio magora 2>/dev/null || true

# Write credentials
log "Writing credentials..."
cat > /home/magora/secrets.env << SECRETSEOF
SUPABASE_URL=$SUPABASE_URL
SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
NODE_EMAIL=$NODE_EMAIL
NODE_PASSWORD=$NODE_PASSWORD
NODE_ID=$NODE_ID
SECRETSEOF
chmod 600 /home/magora/secrets.env

# Write location
cat > /home/magora/location.json << LOCEOF
{
  "lat": $LAT,
  "lon": $LON,
  "name": "$NODE_NAME"
}
LOCEOF

# Download firmware scripts
# Update DETECT_SHA intentionally when releasing a new firmware version.
DETECT_SHA=f0c1940acd7b35877e0af44a810fc3d2bc27ab9a
log "Downloading detect.py (${DETECT_SHA:0:7})..."
wget -q -O /home/magora/detect.py \
  "https://raw.githubusercontent.com/magora-project/magora-acoustic-biodiversity/${DETECT_SHA}/firmware/detect.py"

log "Downloading birdnet.service..."
wget -q -O /etc/systemd/system/birdnet.service \
  https://raw.githubusercontent.com/magora-project/magora-acoustic-biodiversity/main/firmware/birdnet.service
systemctl daemon-reload

# Set up Python environment
log "Checking Python environment..."
if /home/magora/birdnet-env/bin/python3 -c "import birdnetlib, librosa" 2>/dev/null; then
  log "Python environment OK (birdnetlib + librosa verified)."
else
  log "Pre-installed env incomplete — running pip install (takes 30-40 min on Pi Zero 2W)..."

  # Swap helps prevent OOM during large pip builds
  fallocate -l 512M /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile || true

  apt-get update -q 2>&1 | tail -1 >> "$STATUS_FILE"
  apt-get install -y -q python3-venv 2>&1 | tail -1 >> "$STATUS_FILE"
  python3 -m venv /home/magora/birdnet-env

  pip_pkg() {
    log "  pip: $1..."
    if timeout 600 /home/magora/birdnet-env/bin/pip install --prefer-binary -q "$1"; then
      log "  $1 OK"
    else
      log "  WARNING: $1 failed or timed out (exit $?)"
    fi
  }

  pip_pkg "numpy"
  pip_pkg "requests"
  pip_pkg "astral"
  pip_pkg "soundfile"
  pip_pkg "ai-edge-litert"
  pip_pkg "librosa"
  pip_pkg "birdnetlib"

  PYVER=$(/home/magora/birdnet-env/bin/python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  TFLITE="/home/magora/birdnet-env/lib/python${PYVER}/site-packages/tflite_runtime"
  mkdir -p "$TFLITE"
  printf '' > "$TFLITE/__init__.py"
  printf 'from ai_edge_litert.interpreter import Interpreter\ntry:\n    from ai_edge_litert.interpreter import load_delegate\nexcept ImportError:\n    load_delegate = None\n' > "$TFLITE/interpreter.py"

  swapoff /swapfile && rm /swapfile || true
  log "Python install complete."
fi

chown -R magora:magora /home/magora

# Start BirdNET
log "Enabling and starting birdnet.service..."
systemctl enable birdnet.service
systemctl start birdnet.service

# Verify it started
sleep 15
if systemctl is-active --quiet birdnet.service; then
  log "birdnet.service is running."
else
  log "WARNING: birdnet.service failed to start. Check: journalctl -u birdnet"
fi

# Mark complete and disable self
touch "$COMPLETE_FLAG"
systemctl disable magora-firstrun.service
log "=== Magora Firstrun Complete — $NODE_NAME is now active ==="
