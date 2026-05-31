#!/usr/bin/env bash
# install.sh — Install NixOS on a selected drive
#
# Usage:
#   sudo ./install.sh /dev/disk/by-id/nvme-Samsung_SSD_XYZ
#
# This script:
#   1. Verifies the target drive exists
#   2. Runs disko (partition, LUKS encrypt, create ZFS pool)
#   3. Installs NixOS from this flake
#
# Safety: ONLY operates on the drive you explicitly pass.
#         Does NOT touch anything else.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Safety checks ─────────────────────────────────────
if [ $# -ne 1 ]; then
    echo "Usage: $0 /dev/disk/by-id/nvme-<YOUR-DRIVE>"
    echo ""
    echo "Available drives:"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE | grep disk
    exit 1
fi

TARGET_DEVICE="$1"

if [ ! -b "$TARGET_DEVICE" ]; then
    echo "❌ $TARGET_DEVICE is not a block device"
    echo "   Run: lsblk -o NAME,SIZE,MODEL,SERIAL to find your target"
    exit 1
fi

echo "═══════════════════════════════════════════════"
echo "  Target drive: $TARGET_DEVICE"
echo "  Config:       $SCRIPT_DIR"
echo ""
lsblk "$TARGET_DEVICE"
echo "═══════════════════════════════════════════════"
echo ""
read -rp "⚠️  This will DESTROY ALL DATA on $TARGET_DEVICE. Continue? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 2
fi

# ── Build a temporary disko config with the right device ──
# We inject the device path by creating a wrapper that
# overrides the diskDevice argument.
DISKO_NIX=$(mktemp /tmp/disko-config.XXXXXX.nix)
cleanup() { rm -f "$DISKO_NIX"; }
trap cleanup EXIT

cat > "$DISKO_NIX" << EOF
{ ... }:
{
  imports = [
    (import ${SCRIPT_DIR}/hosts/p51/disko-config.nix {
      diskDevice = "${TARGET_DEVICE}";
    })
  ];
}
EOF

# ── Run disko ──────────────────────────────────────────
echo ""
echo "💿 Partitioning, encrypting, and creating ZFS pool..."
sudo nix run github:nix-community/disko -- --mode disko "$DISKO_NIX"

# ── Install NixOS ──────────────────────────────────────
echo ""
echo "📦 Installing NixOS..."
sudo nixos-install --flake "$SCRIPT_DIR#p51" --root /mnt

echo ""
echo "✅ Done! Set your password and reboot:"
echo "   sudo passwd liam"
echo "   sudo reboot"
