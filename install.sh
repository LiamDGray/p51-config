#!/usr/bin/env bash
# install.sh — Install NixOS on a selected drive
#
# Usage:
#   sudo ./install.sh /dev/disk/by-id/nvme-Samsung_SSD_XYZ
#   sudo ./install.sh /dev/disk/by-id/nvme-Samsung_SSD_XYZ --cryptroot-size 468G
#
# The --cryptroot-size flag limits the root LUKS partition so it fits
# within a smaller drive (for future RAID 1 mirror).
#
# To calculate the size:
#   1. Check both drives: lsblk -o NAME,SIZE
#   2. Pick the smaller drive's total size (e.g. 476.9G for a 512GB)
#   3. Subtract ESP (512M) and swap (8G): 476.9 - 0.5 - 8 ≈ 468G
#   4. Pass that as --cryptroot-size 468G
#
# Safety: ONLY operates on the drive you explicitly pass.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse args ────────────────────────────────────────
TARGET_DEVICE=""
CRYPTROOT_SIZE="100%"

while [ $# -gt 0 ]; do
    case "$1" in
        --cryptroot-size)
            CRYPTROOT_SIZE="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$TARGET_DEVICE" ]; then
                TARGET_DEVICE="$1"
                shift
            else
                echo "Unexpected argument: $1"
                exit 1
            fi
            ;;
    esac
done

# ── Safety checks ─────────────────────────────────────
if [ -z "$TARGET_DEVICE" ]; then
    echo "Usage: $0 /dev/disk/by-id/nvme-<YOUR-DRIVE> [--cryptroot-size SIZE]"
    echo ""
    echo "Available drives:"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE | grep disk
    exit 1
fi

if [ ! -b "$TARGET_DEVICE" ]; then
    echo "❌ $TARGET_DEVICE is not a block device"
    echo "   Run: lsblk -o NAME,SIZE,MODEL,SERIAL to find your target"
    exit 1
fi

echo "═══════════════════════════════════════════════"
echo "  Target drive:  $TARGET_DEVICE"
echo "  cryptroot size: $CRYPTROOT_SIZE"
echo "  Config:        $SCRIPT_DIR"
echo ""
lsblk "$TARGET_DEVICE"
echo "═══════════════════════════════════════════════"

if [ "$CRYPTROOT_SIZE" != "100%" ]; then
    echo ""
    echo "⚠️  cryptroot limited to $CRYPTROOT_SIZE (for future mirror compatibility)"
fi
echo ""
read -rp "⚠️  This will DESTROY ALL DATA on $TARGET_DEVICE. Continue? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 2
fi

# ── Build a temporary disko config with the right device and size ──
DISKO_NIX=$(mktemp /tmp/disko-config.XXXXXX.nix)
cleanup() { rm -f "$DISKO_NIX"; }
trap cleanup EXIT

cat > "$DISKO_NIX" << EOF
{ ... }:
{
  imports = [
    (import ${SCRIPT_DIR}/hosts/p51/disko-config.nix {
      diskDevice = "${TARGET_DEVICE}";
      cryptrootSize = "${CRYPTROOT_SIZE}";
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
echo ""
echo "📝 Note: if you used --cryptroot-size, update hosts/p51/default.nix"
echo "   to set cryptrootSize = \"${CRYPTROOT_SIZE}\" so nixos-rebuild uses"
echo "   the same partition size."
