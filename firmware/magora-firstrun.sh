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
WIFI_COUNTRY=$(read_config wifi_country)
[ -z "$WIFI_COUNTRY" ] && WIFI_COUNTRY="US"
SSH_PASSWORD=$(read_config ssh_password)

log "Node: $NODE_NAME"

# Set this node's SSH password, if the config carries one.
#
# The image ships the `pi` account locked (customize-image.sh randomises its password and discards
# the plaintext), so SSH is unreachable until this runs. That makes shared-credential access
# impossible: a node is only reachable with the password its own config gave it. Configs written
# before this field existed simply leave the account locked, which is the safe outcome.
if [ -n "$SSH_PASSWORD" ]; then
  echo "pi:$SSH_PASSWORD" | chpasswd
  log "SSH password set for this node."
else
  log "No ssh_password in config — pi account stays locked (SSH unavailable)."
fi

# Configure WiFi
log "Configuring WiFi ($WIFI_SSID)..."
# Set the WiFi regulatory country FIRST. Pi OS keeps the WiFi radio soft-blocked
# until a country is set, and 5GHz channels are unavailable without it — the #1
# cause of "boots fine but never joins WiFi" (cost us hours on the first 3B+ node).
# Defaults to US; override with a "wifi_country" field in magora-config.json.
log "Setting WiFi country ($WIFI_COUNTRY)..."
raspi-config nonint do_wifi_country "$WIFI_COUNTRY" 2>/dev/null || true
rfkill unblock wifi 2>/dev/null || true
iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
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

# From `release`, NOT `main`. Everything a stranger's node fetches at first boot comes from a
# pointer that only advances after the walkthrough has been re-verified against it — otherwise
# every unverified commit to main is coupled to somebody's first-boot experience, and "it broke"
# becomes unreproducible because main has moved since. detect.py is pinned harder still (an exact
# SHA above); this file changes rarely, so a verified branch pointer is proportionate.
log "Downloading birdnet.service..."
wget -q -O /etc/systemd/system/birdnet.service \
  https://raw.githubusercontent.com/magora-project/magora-acoustic-biodiversity/release/firmware/birdnet.service
systemctl daemon-reload

# Set up Python environment
#
# The image ships this environment pre-installed and verified (the build loads the BirdNET model
# under emulation and refuses to publish an image where that fails), so the healthy path here is a
# check that passes in a second. The rebuild below is a repair path, not the normal route.
REQUIREMENTS="/usr/local/share/magora/requirements.txt"

# Check what actually has to work, not a proxy for it.
#
# This check used to be `import birdnetlib, librosa`. Both of those can import while the thing that
# matters still fails, and in August 2026 they did: librosa 1.0.0 dropped `audioread`, birdnetlib
# imports audioread at module scope without declaring it, and `from birdnetlib import Recording` —
# the exact line detect.py runs — died with ModuleNotFoundError. So check that line itself, plus the
# shim birdnetlib reaches the model through.
env_ok() {
  /home/magora/birdnet-env/bin/python3 -c "
import numpy, requests, astral, soundfile, audioread, librosa
import tflite_runtime.interpreter
from birdnetlib import Recording
from birdnetlib.analyzer import Analyzer
" 2>/dev/null
}

log "Checking Python environment..."
if env_ok; then
  log "Python environment OK (pre-installed, imports verified)."
else
  log "WARNING: pre-installed env is unusable — rebuilding from pinned requirements."
  log "This should not happen on a current image. Expect 15-40 minutes."

  # Swap helps prevent OOM during large pip installs
  fallocate -l 512M /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile || true

  apt-get update -q 2>&1 | tail -1 >> "$STATUS_FILE"
  apt-get install -y -q python3-venv 2>&1 | tail -1 >> "$STATUS_FILE"
  rm -rf /home/magora/birdnet-env
  python3 -m venv /home/magora/birdnet-env

  # Prefer the pins baked into the image; fetch them only if this is an older image that predates
  # them. Never fall back to unpinned installs — that is the bug this whole path exists to repair.
  if [ ! -f "$REQUIREMENTS" ]; then
    log "No baked requirements.txt — fetching pins from release..."
    mkdir -p /usr/local/share/magora
    wget -q -O "$REQUIREMENTS" \
      https://raw.githubusercontent.com/magora-project/magora-acoustic-biodiversity/release/firmware/requirements.txt \
      || log "ERROR: could not fetch requirements.txt."
  fi

  if [ -s "$REQUIREMENTS" ]; then
    log "Installing pinned requirements (wheels only)..."
    # --only-binary=:all: — a Pi must never be asked to compile scipy. Better to fail in a minute
    # with a clear message than to grind for hours and fail anyway.
    # --index-url — Pi OS points pip at piwheels as an extra index; it carries non-PEP440 relics
    # (joblib-0.7.0d) that produce alarming "Invalid wheel filename" noise. Every pin resolves on
    # PyPI proper, so use only that.
    if /home/magora/birdnet-env/bin/pip install \
         --no-cache-dir --only-binary=:all: --index-url https://pypi.org/simple \
         -r "$REQUIREMENTS" 2>&1 | tail -5 >> "$STATUS_FILE"; then
      log "pip install finished."
    else
      log "ERROR: pinned pip install failed."
    fi
  fi

  PYVER=$(/home/magora/birdnet-env/bin/python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  TFLITE="/home/magora/birdnet-env/lib/python${PYVER}/site-packages/tflite_runtime"
  mkdir -p "$TFLITE"
  printf '' > "$TFLITE/__init__.py"
  printf 'from ai_edge_litert.interpreter import Interpreter\ntry:\n    from ai_edge_litert.interpreter import load_delegate\nexcept ImportError:\n    load_delegate = None\n' > "$TFLITE/interpreter.py"

  swapoff /swapfile && rm /swapfile || true

  if env_ok; then
    log "Python environment rebuilt successfully."
  else
    log "ERROR: environment still incomplete after rebuild. birdnet will not start."
    log "Details: $(/home/magora/birdnet-env/bin/python3 -c 'from birdnetlib import Recording' 2>&1 | tail -1)"
  fi
fi

chown -R magora:magora /home/magora

# Start BirdNET
log "Enabling and starting birdnet.service..."
systemctl enable birdnet.service
systemctl start birdnet.service || true

# Verify it actually stayed up.
#
# `systemctl start` returning, and even systemd logging "Started birdnet.service", says only that
# the process was spawned. detect.py died on an import a moment later, and because the unit is
# Restart=always it kept being respawned — so a single instantaneous check can catch it mid-restart
# and read as healthy. Watch it for a while and require it to be up at the end AND not to have
# accumulated restarts.
log "Watching birdnet.service for 45s..."
sleep 45
BIRDNET_STATE=$(systemctl is-active birdnet.service 2>/dev/null || true)
BIRDNET_RESTARTS=$(systemctl show birdnet.service -p NRestarts --value 2>/dev/null || echo 0)

if [ "$BIRDNET_STATE" = "active" ] && [ "${BIRDNET_RESTARTS:-0}" -eq 0 ]; then
  BIRDNET_OK=yes
else
  BIRDNET_OK=no
fi

# Mark complete and disable self
touch "$COMPLETE_FLAG"
systemctl disable magora-firstrun.service

# The verdict, written where a steward can actually read it.
#
# This is the change that matters most for anyone debugging a node. A node that joins Wi-Fi but
# never listens looks identical from outside to one that is working — the portal just says "no
# heartbeat yet" — and the steward has no monitor, no keyboard, and no password. What they DO have
# is a card reader: /boot/firmware is the FAT partition that mounts as `bootfs` on any laptop.
#
# So the last thing firstrun does is write a plain verdict there. Previously it printed
# "...is now active" unconditionally, including on the boot where birdnet was dead — a false
# success banner that sent one debugging session looking everywhere except at the actual failure.
{
  echo ""
  echo "================ MAGORA NODE STATUS ================"
  echo "node:      $NODE_NAME ($NODE_ID)"
  echo "firstrun:  complete at $(date '+%Y-%m-%d %H:%M:%S')"
  if [ "$BIRDNET_OK" = "yes" ]; then
    echo "birdnet:   active"
    echo ""
    echo "This node is listening. Detections should appear on its portal page"
    echo "within the hour."
  else
    echo "birdnet:   FAILED TO START  (state=$BIRDNET_STATE restarts=$BIRDNET_RESTARTS)"
    echo ""
    echo "This node is on the network but is NOT listening. Nothing will appear"
    echo "on its portal page until this is fixed."
    echo ""
    echo "The error is in birdnet.log, on this same drive — open it and read the"
    echo "last few lines. The most useful line is usually the final one."
    echo ""
    echo "Last lines of the service log:"
    tail -n 20 /boot/firmware/birdnet.log 2>/dev/null | sed 's/^/    /' || echo "    (birdnet.log not written yet)"
    echo ""
    echo "With SSH access, more detail: journalctl -u birdnet -n 100"
  fi
  echo "===================================================="
} >> "$STATUS_FILE" 2>/dev/null || true

if [ "$BIRDNET_OK" = "yes" ]; then
  log "=== Magora Firstrun Complete — $NODE_NAME is now active ==="
else
  log "=== Magora Firstrun FAILED — $NODE_NAME is NOT listening ==="
  log "birdnet.service did not stay up (state=$BIRDNET_STATE, restarts=$BIRDNET_RESTARTS)."
  log "Read birdnet.log on the bootfs drive, or: journalctl -u birdnet -n 100"
  exit 1
fi
