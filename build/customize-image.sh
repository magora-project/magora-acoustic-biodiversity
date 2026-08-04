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

cleanup() {
  echo "Cleaning up mounts..."
  umount "$MOUNT_DIR/boot" 2>/dev/null || true
  umount "$MOUNT_DIR/root" 2>/dev/null || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
  rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

echo "=== Magora Image Builder ==="
echo "Image: $IMAGE"

LOOP=$(losetup -f --show -P "$IMAGE")
echo "Loop device: $LOOP"

mkdir -p "$MOUNT_DIR/boot" "$MOUNT_DIR/root"
mount "${LOOP}p1" "$MOUNT_DIR/boot"
mount "${LOOP}p2" "$MOUNT_DIR/root"

# Install firstrun script
echo "Installing magora-firstrun.sh..."
cp "$FIRMWARE_DIR/magora-firstrun.sh" "$MOUNT_DIR/root/usr/local/bin/magora-firstrun.sh"
chmod +x "$MOUNT_DIR/root/usr/local/bin/magora-firstrun.sh"

# Install firstrun service
echo "Installing magora-firstrun.service..."
cp "$FIRMWARE_DIR/magora-firstrun.service" "$MOUNT_DIR/root/etc/systemd/system/magora-firstrun.service"

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

echo "=== Image customization complete ==="
