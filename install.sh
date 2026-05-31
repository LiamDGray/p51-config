#!/usr/bin/env bash
# install.sh — Install NixOS on a selected drive
#
# Usage (auto-detect — picks the non-NTFS NVMe drive):
#   sudo ./install.sh
#
# Usage (explicit):
#   sudo ./install.sh /dev/disk/by-id/nvme-Samsung_SSD_XYZ
#   sudo ./install.sh /dev/disk/by-id/nvme-Samsung_SSD_XYZ --cryptroot-size 468G
#
# Auto-sizing: if --cryptroot-size is omitted, the script measures the
# smallest NVMe drive and sizes cryptroot to fit on it (for future
# RAID 1 mirror compatibility).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ────────────────────────────────────────────
die() { echo "❌ $*" >&2; exit 1; }
bytes_to_gib() { python3 -c "print(f'{round($1 / 1024**3, 1)}')"; }

# ── Detect all NVMe drives ─────────────────────────────
# Returns array of /dev/nvmeXnY paths
detect_nvme_drives() {
    lsblk -d -n -o NAME,TYPE 2>/dev/null \
        | awk '/disk/ && /nvme/ {print "/dev/"$1}'
}

# ── Get the stable by-id path for a /dev/nvmeXnY device ──
to_by_id() {
    local dev="$1"
    # Find the nvme-* or nvme-eui.* symlink pointing to this device
    local basename; basename=$(basename "$(realpath "$dev" 2>/dev/null)" 2>/dev/null)
    if [ -z "$basename" ]; then
        echo "$dev"
        return
    fi
    local byid
    byid=$(readlink -f /dev/disk/by-id/nvme-* 2>/dev/null \
        | grep "/$basename\$" | head -1)
    if [ -n "$byid" ] && [ -b "$byid" ]; then
        echo "$byid"
        return
    fi
    # Fallback: use by-path
    byid=$(readlink -f /dev/disk/by-path/*-nvme-* 2>/dev/null \
        | grep "/$basename\$" | head -1)
    if [ -n "$byid" ] && [ -b "$byid" ]; then
        echo "$byid"
        return
    fi
    echo "$dev"
}

# ── Check if a drive has any NTFS partitions ────────────
has_ntfs() {
    local dev="$1"
    local cnt
    cnt=$(lsblk "$dev" -n -o FSTYPE 2>/dev/null | grep -ci "ntfs" || true)
    [ "$cnt" -gt 0 ]
}

# ── Get drive capacity in bytes ─────────────────────────
drive_bytes() {
    local dev="$1"
    lsblk -d -b -n -o SIZE "$dev" 2>/dev/null || echo 0
}

# ── Get the actual kernel device name for a path ────────
dev_basename() {
    basename "$(realpath "$1" 2>/dev/null)" 2>/dev/null || basename "$1"
}

# ═════════════════════════════════════════════════════════
#  PHASE 1: Auto-detect drives
# ═════════════════════════════════════════════════════════

echo "🔍 Scanning NVMe drives..."

ALL_NVME=()
while IFS= read -r dev; do
    [ -n "$dev" ] && ALL_NVME+=("$dev")
done < <(detect_nvme_drives)

if [ ${#ALL_NVME[@]} -eq 0 ]; then
    die "No NVMe drives found"
fi

NTFS_DRIVES=()
TARGET_CANDIDATES=()

for dev in "${ALL_NVME[@]}"; do
    if has_ntfs "$dev"; then
        NTFS_DRIVES+=("$dev")
    else
        TARGET_CANDIDATES+=("$dev")
    fi
done

# ── Parse flags (before positional arg) ─────────────────
TARGET_DEVICE=""
CRYPTROOT_SIZE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cryptroot-size)
            CRYPTROOT_SIZE="$2"
            shift 2
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            if [ -z "$TARGET_DEVICE" ]; then
                TARGET_DEVICE="$1"
                shift
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
done

# ── Select target ───────────────────────────────────────
if [ -n "$TARGET_DEVICE" ]; then
    # Explicit target — validate it exists
    if [ ! -b "$TARGET_DEVICE" ]; then
        die "$TARGET_DEVICE is not a block device"
    fi
    echo "  Explicit target: $TARGET_DEVICE"
else
    # Auto-detect: non-NTFS NVMe drive
    case ${#TARGET_CANDIDATES[@]} in
        0)
            echo ""
            echo "All NVMe drives have NTFS partitions. Can't determine target."
            echo "Please specify one explicitly:"
            for d in "${ALL_NVME[@]}"; do
                echo "  $(to_by_id "$d")"
            done
            exit 1
            ;;
        1)
            TARGET_DEVICE="$(to_by_id "${TARGET_CANDIDATES[0]}")"
            echo "  Auto-selected target: $TARGET_DEVICE"
            ;;
        *)
            echo ""
            echo "Multiple NVMe drives without NTFS found. Please specify:"
            for d in "${TARGET_CANDIDATES[@]}"; do
                echo "  $(to_by_id "$d")"
            done
            exit 1
            ;;
    esac
fi

# ── Resolve to kernel device for size detection ─────────
TARGET_KERNEL=""
for d in "${ALL_NVME[@]}"; do
    if [ "$(to_by_id "$d")" = "$TARGET_DEVICE" ] || [ "$d" = "$TARGET_DEVICE" ]; then
        TARGET_KERNEL="$d"
        break
    fi
done
if [ -z "$TARGET_KERNEL" ]; then
    # Try readlink from the by-id path
    TARGET_KERNEL=$(readlink -f "$TARGET_DEVICE" 2>/dev/null || echo "")
    if [ -z "$TARGET_KERNEL" ] || [ ! -b "$TARGET_KERNEL" ]; then
        die "Cannot resolve $TARGET_DEVICE"
    fi
fi

# ── Find the constraint drive (for mirror sizing) ──────
# The constraint is the SMALLER of the target and the NTFS drive.
# We size cryptroot to fit on whichever is smaller.
TARGET_BYTES=$(drive_bytes "$TARGET_KERNEL")
CONSTRAINT_BYTES=$TARGET_BYTES  # default: target itself

if [ ${#NTFS_DRIVES[@]} -gt 0 ]; then
    for ntfs_dev in "${NTFS_DRIVES[@]}"; do
        ntfs_bytes=$(drive_bytes "$ntfs_dev")
        if [ "$ntfs_bytes" -gt 0 ] && [ "$ntfs_bytes" -lt "$CONSTRAINT_BYTES" ]; then
            CONSTRAINT_BYTES=$ntfs_bytes
        fi
    done
fi

# ═════════════════════════════════════════════════════════
#  PHASE 2: Calculate cryptroot size
# ═════════════════════════════════════════════════════════

TARGET_GIB=$(bytes_to_gib "$TARGET_BYTES")
CONSTRAINT_GIB=$(bytes_to_gib "$CONSTRAINT_BYTES")

if [ -z "$CRYPTROOT_SIZE" ]; then
    if [ "$CONSTRAINT_BYTES" -lt "$TARGET_BYTES" ]; then
        # Target is bigger than constraint → limit cryptroot
        # ESP=0.5G, swap=8G → usable = constraint - 8.5G in GiB
        USABLE_GIB=$(python3 -c "
import math
usable = $CONSTRAINT_BYTES / 1024**3 - 8.5
# Round down to nearest whole GiB
usable = math.floor(usable)
print(f'{usable}G')
")
        CRYPTROOT_SIZE="$USABLE_GIB"
        echo ""
        echo "  ⚖️  Target: ${TARGET_GIB}G  |  Constraint (smaller drive): ${CONSTRAINT_GIB}G"
        echo "  📐 cryptroot sized to ${CRYPTROOT_SIZE} (fits both drives for future mirror)"
    else
        CRYPTROOT_SIZE="100%"
        echo ""
        echo "  ⚖️  Target: ${TARGET_GIB}G  |  Target is the smallest drive"
        echo "  📐 cryptroot set to 100% of remaining space"
    fi
fi

# ═════════════════════════════════════════════════════════
#  PHASE 3: Confirmation
# ═════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════"
echo "  Target drive:  $TARGET_DEVICE  (${TARGET_GIB}G)"
echo "  cryptroot:     $CRYPTROOT_SIZE"
echo "  Config:        $SCRIPT_DIR"
echo ""

lsblk "$(realpath "$TARGET_KERNEL")" -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null || true
echo ""

echo "  Other drives detected:"
for d in "${ALL_NVME[@]}"; do
    id="$(to_by_id "$d")"
    if [ "$id" != "$TARGET_DEVICE" ] && [ "$d" != "$TARGET_DEVICE" ]; then
        bytes=$(drive_bytes "$d")
        gib=$(bytes_to_gib "$bytes")
        echo "    $id  (${gib}G)"
    fi
done
echo "═══════════════════════════════════════════════"

if [ "$CRYPTROOT_SIZE" != "100%" ]; then
    echo ""
    echo "⚠️  cryptroot limited to $CRYPTROOT_SIZE for mirror compatibility"
    echo "   ${CONSTRAINT_GIB}G is the smallest drive that future pool members must fit on."
fi
echo ""
read -rp "⚠️  This will DESTROY ALL DATA on the target drive. Continue? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 2
fi

# ═════════════════════════════════════════════════════════
#  PHASE 4: Run disko
# ═════════════════════════════════════════════════════════

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

echo ""
echo "💿 Partitioning, encrypting, and creating ZFS pool..."
sudo nix run github:nix-community/disko -- --mode disko "$DISKO_NIX"

# ═════════════════════════════════════════════════════════
#  PHASE 5: Install NixOS
# ═════════════════════════════════════════════════════════

echo ""
echo "📦 Installing NixOS..."
sudo nixos-install --flake "$SCRIPT_DIR#p51" --root /mnt

echo ""
echo "✅ Done!"
echo ""
echo "   Next steps:"
echo "   ─────────────────────────────────────────────"
echo "   1. sudo passwd liam"
echo "   2. sudo reboot"
echo "   ─────────────────────────────────────────────"
echo ""
echo "   After reboot, update hosts/p51/default.nix:"
echo "   - diskDevice = \"${TARGET_DEVICE}\""
if [ "$CRYPTROOT_SIZE" != "100%" ]; then
    echo "   - cryptrootSize = \"${CRYPTROOT_SIZE}\""
fi
