#!/bin/bash
# Customizes a Pi OS image into the Magora Node image
# Usage: sudo bash customize-image.sh <image.img>
# Run by GitHub Actions — not intended for manual use

set -e

IMAGE=$1
if [ -z "$IMAGE" ]; then
  echo "Usage: $0 <image.img>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIRMWARE_DIR="$SCRIPT_DIR/../firmware"
MOUNT_DIR=$(mktemp -d)

# How much to grow the image so the Python environment fits. See "Growing the root filesystem".
GROW_BY=3G

cleanup() {
  echo "Cleaning up mounts..."
  umount "$MOUNT_DIR/root/dev/pts" 2>/dev/null || true
  umount "$MOUNT_DIR/root/dev"     2>/dev/null || true
  umount "$MOUNT_DIR/root/sys"     2>/dev/null || true
  umount "$MOUNT_DIR/root/proc"    2>/dev/null || true
  umount "$MOUNT_DIR/boot" 2>/dev/null || true
  umount "$MOUNT_DIR/root" 2>/dev/null || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
  rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

echo "=== Magora Image Builder ==="
echo "Image: $IMAGE"

# --- Growing the root filesystem -------------------------------------------------------------
#
# Pi OS Lite ships a root partition sized to its own contents with almost nothing spare. A previous
# attempt to pre-install the Python environment was abandoned for exactly this reason (2ea4f8b,
# "Drop QEMU chroot — Pi image root partition too small for Python packages") and the work was
# pushed onto the device instead: every node then spent 30-40 minutes running pip on first boot,
# over whatever Wi-Fi it had, resolving whatever PyPI served that day. That is the fallback path
# that shipped a broken environment to every node built after 2026-08-11.
#
# The partition being too small is a solvable problem, so solve it: grow the image, grow the
# partition, grow the filesystem, then install into it. The slack is zero-filled before compression
# below, so it costs almost nothing in the released .xz, and first boot expands the root partition
# to fill the SD card anyway.
echo "Growing image by $GROW_BY to make room for the Python environment..."
truncate -s "+$GROW_BY" "$IMAGE"

LOOP=$(losetup -f --show -P "$IMAGE")
echo "Loop device: $LOOP"

echo "Resizing partition 2 to fill the image..."
parted -s "$LOOP" resizepart 2 100%
partprobe "$LOOP" 2>/dev/null || true
losetup -c "$LOOP" 2>/dev/null || true
sleep 1

# e2fsck exits 1/2 when it corrected something, which is fine and expected here. Only >=4 is a
# real failure, and `set -e` would otherwise abort on a successful repair.
e2fsck -fy "${LOOP}p2" || [ $? -lt 4 ]
resize2fs "${LOOP}p2"

mkdir -p "$MOUNT_DIR/boot" "$MOUNT_DIR/root"
mount "${LOOP}p1" "$MOUNT_DIR/boot"
mount "${LOOP}p2" "$MOUNT_DIR/root"

echo "Root filesystem space after grow:"
df -h "$MOUNT_DIR/root" | tail -1

# Install firstrun script
echo "Installing magora-firstrun.sh..."
cp "$FIRMWARE_DIR/magora-firstrun.sh" "$MOUNT_DIR/root/usr/local/bin/magora-firstrun.sh"
chmod +x "$MOUNT_DIR/root/usr/local/bin/magora-firstrun.sh"

# Install firstrun service
echo "Installing magora-firstrun.service..."
cp "$FIRMWARE_DIR/magora-firstrun.service" "$MOUNT_DIR/root/etc/systemd/system/magora-firstrun.service"

# Bake the pinned requirements into the image.
#
# firstrun.sh reads this file if it ever has to rebuild the environment on-device. It must come from
# the image rather than being fetched, so that the repair path works on a node with flaky networking
# — and so that it is exactly the set this build verified, not whatever the branch says later.
echo "Installing pinned requirements.txt..."
mkdir -p "$MOUNT_DIR/root/usr/local/share/magora"
cp "$FIRMWARE_DIR/requirements.txt" "$MOUNT_DIR/root/usr/local/share/magora/requirements.txt"

# Enable firstrun service
echo "Enabling magora-firstrun.service..."
mkdir -p "$MOUNT_DIR/root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/magora-firstrun.service \
  "$MOUNT_DIR/root/etc/systemd/system/multi-user.target.wants/magora-firstrun.service"

# Enable SSH (try both possible paths for Bookworm)
echo "Enabling SSH..."
SSH_SRC=""
for candidate in \
  "$MOUNT_DIR/root/lib/systemd/system/ssh.service" \
  "$MOUNT_DIR/root/usr/lib/systemd/system/ssh.service"; do
  [ -f "$candidate" ] && { SSH_SRC="${candidate#$MOUNT_DIR/root}"; break; }
done
if [ -n "$SSH_SRC" ]; then
  ln -sf "$SSH_SRC" \
    "$MOUNT_DIR/root/etc/systemd/system/multi-user.target.wants/ssh.service"
fi
# Belt-and-suspenders: ssh touchfile on bootfs
touch "$MOUNT_DIR/boot/ssh"

# Create the `pi` account with an UNKNOWABLE password.
#
# Pi OS requires a user account to exist or first boot stalls waiting for one, so we cannot simply
# omit this. But the image is a public download and this repo is public, so any password written
# here is a published credential on every node built from it — including strangers' nodes, on their
# home networks. This previously baked in `pi / magora123`.
#
# Instead: generate a random password, write only its hash, and never record the plaintext. The
# account exists (Pi OS is happy) and nobody can log into it. magora-firstrun.sh then sets a real
# password from the per-node `ssh_password` in magora-config.json, so remote debugging still works —
# with a credential unique to each node rather than shared by all of them.
echo "Creating locked pi account (password randomised and discarded)..."
HASH=$(openssl passwd -6 "$(openssl rand -base64 32)")
echo "pi:$HASH" > "$MOUNT_DIR/boot/userconf.txt"

# Enable I2S mic overlay
echo "Enabling I2S mic overlay..."
CONFIG_TXT="$MOUNT_DIR/boot/config.txt"
grep -q "adau7002-simple" "$CONFIG_TXT" 2>/dev/null || \
  printf "\ndtparam=i2s=on\ndtoverlay=adau7002-simple\n" >> "$CONFIG_TXT"

# --- Pre-install the Python environment (QEMU chroot) -----------------------------------------
#
# Runs on the x86_64 GitHub runner, executing aarch64 binaries under qemu-user via binfmt. The
# result is a complete, working venv baked into the image, so a node's first boot enables a service
# rather than compiling a scientific Python stack over a stranger's Wi-Fi.
#
# Everything here is deliberately strict, because the whole class of bug this replaces was caused by
# leniency:
#   --only-binary=:all:  a missing aarch64 wheel fails THIS build, instead of silently starting a
#                        40-minute source compile on someone's Pi.
#   -r requirements.txt  exact pins, so the environment is a function of the repo, not of the day.
#   --index-url pypi     Pi OS ships /etc/pip.conf pointing at piwheels as an extra index. piwheels
#                        carries non-PEP440 relics (joblib-0.7.0d-py3-none-any.whl really is on
#                        there), which is where the "Invalid wheel filename" noise in the field logs
#                        came from. Every pin above resolves to a manylinux aarch64 wheel on PyPI
#                        proper, so we don't need piwheels and don't accept its index.
#   verification         imports AND a real Analyzer() model load, as a hard build gate. An image
#                        that cannot load the BirdNET model must not be publishable.
echo "Pre-installing Python environment under QEMU (this is the slow step)..."
if [ ! -f /usr/bin/qemu-aarch64-static ]; then
  echo "Installing qemu-user-static..."
  apt-get update -q
  apt-get install -y -q qemu-user-static binfmt-support
fi
cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/root/usr/bin/"
cp /etc/resolv.conf "$MOUNT_DIR/root/etc/resolv.conf"
mount --bind /proc    "$MOUNT_DIR/root/proc"
mount --bind /sys     "$MOUNT_DIR/root/sys"
mount --bind /dev     "$MOUNT_DIR/root/dev"
mount --bind /dev/pts "$MOUNT_DIR/root/dev/pts"

chroot "$MOUNT_DIR/root" /bin/bash << 'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive

echo "-- Target interpreter: $(python3 --version)"

echo "-- Updating package lists..."
apt-get update -q

echo "-- Installing python3-venv..."
apt-get install -y -q python3-venv

echo "-- Creating magora user..."
useradd -r -s /bin/bash -d /home/magora magora 2>/dev/null || true
mkdir -p /home/magora

echo "-- Creating Python venv..."
python3 -m venv /home/magora/birdnet-env

echo "-- Installing pinned requirements (wheels only, PyPI only)..."
/home/magora/birdnet-env/bin/pip install \
  --no-cache-dir \
  --only-binary=:all: \
  --index-url https://pypi.org/simple \
  -r /usr/local/share/magora/requirements.txt

echo "-- Writing tflite_runtime shim..."
# birdnetlib looks for `tflite_runtime`, the package Google retired. `ai-edge-litert` is its
# supported successor and exposes the same Interpreter. This shim is the adapter between them.
PYVER=$(/home/magora/birdnet-env/bin/python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
TFLITE="/home/magora/birdnet-env/lib/python${PYVER}/site-packages/tflite_runtime"
mkdir -p "$TFLITE"
printf '' > "$TFLITE/__init__.py"
cat > "$TFLITE/interpreter.py" << 'SHIMEOF'
from ai_edge_litert.interpreter import Interpreter
try:
    from ai_edge_litert.interpreter import load_delegate
except ImportError:
    load_delegate = None
SHIMEOF

echo "-- Verifying the environment (hard build gate)..."
/home/magora/birdnet-env/bin/python3 - << 'VERIFYEOF'
import sys
print("python", sys.version.split()[0])

import numpy; print("numpy", numpy.__version__)
import requests, astral, soundfile, audioread
print("soundfile", soundfile.__version__, "| requests/astral/audioread OK")
import librosa; print("librosa", librosa.__version__)
import tflite_runtime.interpreter  # the shim above must resolve to ai-edge-litert
print("tflite_runtime shim OK")

# The import that actually broke in the field: birdnetlib does `import audioread` at module scope
# without declaring the dependency. If audioread ever falls out of the pin set again, this line is
# where the build stops — on a CI runner, not on a steward's windowsill.
from birdnetlib import Recording
from birdnetlib.analyzer import Analyzer
print("birdnetlib imports OK")

# Load the model for real. Imports succeeding proves the env resolves; only this proves it runs.
Analyzer()
print("BirdNET Analyzer model loaded OK")
VERIFYEOF

echo "-- Recording the environment manifest..."
/home/magora/birdnet-env/bin/pip freeze > /usr/local/share/magora/env-manifest.txt

echo "-- Setting ownership..."
chown -R magora:magora /home/magora

echo "-- Cleaning apt caches..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "-- Python environment pre-installed and verified."
CHROOT_EOF

# Copy the manifest to the boot partition too. It is the only part of the image a steward can read
# with the card in a Windows laptop, and "which versions is this node actually running" is the first
# question any future version-drift incident will ask.
cp "$MOUNT_DIR/root/usr/local/share/magora/env-manifest.txt" "$MOUNT_DIR/boot/magora-env-manifest.txt"

umount "$MOUNT_DIR/root/dev/pts" 2>/dev/null || true
umount "$MOUNT_DIR/root/dev"     2>/dev/null || true
umount "$MOUNT_DIR/root/sys"     2>/dev/null || true
umount "$MOUNT_DIR/root/proc"    2>/dev/null || true
rm -f "$MOUNT_DIR/root/usr/bin/qemu-aarch64-static"

echo "Root filesystem space after install:"
df -h "$MOUNT_DIR/root" | tail -1

# Zero the free space so the 3G we added compresses to nothing in the released .xz.
echo "Zero-filling free space for compression..."
dd if=/dev/zero of="$MOUNT_DIR/root/.zerofill" bs=1M status=none 2>/dev/null || true
rm -f "$MOUNT_DIR/root/.zerofill"
sync

echo "=== Image customization complete ==="
