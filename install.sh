#!/usr/bin/env bash
# install.sh — Install NixOS on a ThinkPad P51
#
# Auto-detects the correct NVMe drive (skips any with NTFS partitions)
# and calculates a cryptroot partition size that will later fit on a
# smaller mirror drive.
#
# Usage:
#   sudo ./install.sh                              # auto-detect
#   sudo ./install.sh /dev/nvme0n1                 # explicit
#   sudo ./install.sh /dev/disk/by-id/nvme-XXX     # explicit (by-id)
#
# If auto-detection is ambiguous or any assumption fails, the script
# aborts with a clear message rather than guessing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ═════════════════════════════════════════════════════════
#  Guard: prerequisites
# ═════════════════════════════════════════════════════════

MISSING=""
for cmd in lsblk readlink basename realpath python3 nix sudo; do
    command -v "$cmd" &>/dev/null || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
    echo "❌ Missing required tools:$MISSING"
    echo "   On the NixOS live USB, run: nix-shell -p python3"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Must be run as root (or with sudo)"
    exit 1
fi

# Verify the flake is accessible
DISKO_CONFIG="${SCRIPT_DIR}/hosts/p51/disko-config.nix"
if [ ! -f "$DISKO_CONFIG" ]; then
    echo "❌ Cannot find disko config at $DISKO_CONFIG"
    echo "   Make sure you're running install.sh from the p51-config directory"
    exit 1
fi

# ═════════════════════════════════════════════════════════
#  Helpers
# ═════════════════════════════════════════════════════════

die() { echo "❌ $*" >&2; exit 1; }

gib_from_bytes() {
    local bytes="$1"
    python3 -c "import math; g=math.floor($bytes / 1024**3); print(f'{g}')"
}

# Resolve an NVMe disk device to its stable /dev/disk/by-id/ name.
# Prefers human-readable vendor-model-serial links over EUI links.
#
# Returns the input unchanged if no by-id link is found (safe fallback).
to_by_id() {
    local dev="$1"
    local real_disk
    real_disk=$(realpath "$dev" 2>/dev/null)
    if [ -z "$real_disk" ] || [ ! -b "$real_disk" ]; then
        echo "$dev"
        return
    fi

    local best_eui=""

    # Glob must match at least one entry, or fail
    for link in /dev/disk/by-id/nvme-*; do
        [ -L "$link" ] || continue
        local target
        target=$(readlink -f "$link" 2>/dev/null) || continue
        if [ "$target" = "$real_disk"]; then
            # Prefer non-EUI links (human-readable)
            if [[ "$(basename "$link")" != nvme-eui.* ]]; then
                echo "$link"
                return
            fi
            # Remember the first EUI link as fallback
            [ -z "$best_eui" ] && best_eui="$link"
        fi
    done

    if [ -n "$best_eui" ]; then
        echo "$best_eui"
        return
    fi

    # No by-id link found — fall back to input path
    echo "$dev"
}

# Get the disk device path (e.g. /dev/nvme0n1) from any path
to_disk_device() {
    local dev="$1"
    local r
    r=$(realpath "$dev" 2>/dev/null) || true
    if [ -n "$r" ] && [ -b "$r" ]; then
        echo "$r"
    else
        echo ""
    fi
}

# Check if a specific drive has any partitions with NTFS filesystem
has_ntfs() {
    local dev="$1"
    local fstype_output
    fstype_output=$(lsblk "$dev" -n -o FSTYPE 2>/dev/null) || return 1
    local cnt
    cnt=$(echo "$fstype_output" | grep -c -i "ntfs" 2>/dev/null) || true
    [ "$cnt" -gt 0 ]
}

# Get drive capacity in bytes (raw number, no units)
drive_bytes() {
    local dev="$1"
    local val
    val=$(lsblk -d -b -n -o SIZE "$dev" 2>/dev/null) || true
    if [ -z "$val" ] || [ "$val" -le 0 ] 2>/dev/null; then
        echo "0"
    else
        echo "$val"
    fi
}

# ═════════════════════════════════════════════════════════
#  Phase 1: Parse arguments
# ═════════════════════════════════════════════════════════

ARG_DEVICE=""
ARG_CRYPTROOT_SIZE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cryptroot-size)
            if [ $# -lt 2 ]; then
                die "--cryptroot-size requires an argument (e.g. '230G')"
            fi
            ARG_CRYPTROOT_SIZE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [device] [--cryptroot-size SIZE]"
            echo ""
            echo "  device              Path to target NVMe drive (auto-detected if omitted)"
            echo "  --cryptroot-size    Override cryptroot partition size (auto-calculated if omitted)"
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            if [ -n "$ARG_DEVICE" ]; then
                die "Unexpected extra argument: $1"
            fi
            ARG_DEVICE="$1"
            shift
            ;;
    esac
done

# ═════════════════════════════════════════════════════════
#  Phase 2: Discover NVMe drives
# ═════════════════════════════════════════════════════════

echo "🔍 Scanning NVMe drives..."

# Collect all NVMe disk device paths
ALL_DISKS=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    dev="/dev/$line"
    if [ -b "$dev" ]; then
        ALL_DISKS+=("$(realpath "$dev")")
    fi
done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '/disk/ && /nvme/ {print $1}' || true)

# Partition drives by presence of NTFS
NTFS_DISKS=()
CANDIDATE_DISKS=()

for dev in "${ALL_DISKS[@]}"; do
    if has_ntfs "$dev"; then
        NTFS_DISKS+=("$dev")
    else
        CANDIDATE_DISKS+=("$dev")
    fi
done

# ═════════════════════════════════════════════════════════
#  Phase 3: Select target drive
# ═════════════════════════════════════════════════════════

TARGET_DEVICE=""

if [ -n "$ARG_DEVICE" ]; then
    # ── Explicit target ──────────────────────────────────
    TARGET_DEVICE=$(to_by_id "$ARG_DEVICE")
    TARGET_DISK=$(to_disk_device "$ARG_DEVICE")
    if [ -z "$TARGET_DISK" ]; then
        die "Device does not exist or is not a block device: $ARG_DEVICE"
    fi
    echo "  Explicit target: $TARGET_DEVICE"

elif [ ${#CANDIDATE_DISKS[@]} -eq 0 ]; then
    # ── No candidate NVMe drives found ──────────────────────
    if [ ${#NTFS_DISKS[@]} -gt 0 ]; then
        die "All NVMe drives have NTFS partitions. Cannot determine target."
    elif [ ${#ALL_DISKS[@]} -eq 0 ]; then
        die "No NVMe drives found. This machine may not have NVMe, or you need to pass the device path explicitly."
    else
        die "Cannot identify a suitable target drive. No drive has NTFS but lsblk is not reporting filesystem info. Pass the device path explicitly."
    fi

elif [ ${#CANDIDATE_DISKS[@]} -eq 1 ]; then
    # ── Exactly one candidate — auto-select ─────────────
    TARGET_DISK="${CANDIDATE_DISKS[0]}"
    TARGET_DEVICE=$(to_by_id "$TARGET_DISK")
    echo "  Auto-selected: $TARGET_DEVICE"

else
    # ── Multiple candidates — can't decide ──────────────
    echo ""
    echo "⚠️  Multiple NVMe drives found without NTFS."
    echo "   Please specify one explicitly:"
    for dev in "${CANDIDATE_DISKS[@]}"; do
        id=$(to_by_id "$dev")
        bytes=$(drive_bytes "$dev")
        gib=$(gib_from_bytes "$bytes")
        echo "    $id  (${gib}G)"
    done
    exit 1
fi

# ── Validate target is resolvable and is NVMe ────────────
if [ -z "$TARGET_DISK" ]; then
    TARGET_DISK=$(to_disk_device "$TARGET_DEVICE")
fi
if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    die "Target device $TARGET_DEVICE cannot be resolved"
fi

# Verify it's an NVMe drive by checking the device name
TARGET_DISK_NAME=$(basename "$TARGET_DISK")
if [[ "$TARGET_DISK_NAME" != nvme* ]]; then
    die "Target $TARGET_DEVICE ($TARGET_DISK) does not appear to be an NVMe drive — aborting for safety"
fi

TARGET_BYTES=$(drive_bytes "$TARGET_DISK")
if [ "$TARGET_BYTES" -le 0 ]; then
    die "Cannot read size of target drive $TARGET_DISK"
fi
TARGET_GIB=$(gib_from_bytes "$TARGET_BYTES")

# ═════════════════════════════════════════════════════════
#  Phase 4: Calculate cryptroot size
# ═════════════════════════════════════════════════════════

# The constraint is the SMALLER drive. cryptroot will be sized to fit
# on whichever is smallest — either the target itself, or the NTFS
# drive that might become a mirror member later.

CONSTRAINT_BYTES=$TARGET_BYTES

if [ ${#NTFS_DISKS[@]} -gt 0 ]; then
    for ntfs_dev in "${NTFS_DISKS[@]}"; do
        ntfs_bytes=$(drive_bytes "$ntfs_dev")
        if [ "$ntfs_bytes" -gt 0 ] && [ "$ntfs_bytes" -lt "$CONSTRAINT_BYTES" ]; then
            CONSTRAINT_BYTES=$ntfs_bytes
        fi
    done
fi

# Also check other candidate drives that aren't the target
for other_dev in "${CANDIDATE_DISKS[@]}"; do
    if [ "$(realpath "$other_dev")" = "$(realpath "$TARGET_DISK")" ]; then
        continue
    fi
    other_bytes=$(drive_bytes "$other_dev")
    if [ "$other_bytes" -gt 0 ] && [ "$other_bytes" -lt "$CONSTRAINT_BYTES" ]; then
        CONSTRAINT_BYTES=$other_bytes
    fi
done

CONSTRAINT_GIB=$(gib_from_bytes "$CONSTRAINT_BYTES")

if [ -n "$ARG_CRYPTROOT_SIZE" ]; then
    # User supplied an explicit size — trust it
    CRYPTROOT_SIZE="$ARG_CRYPTROOT_SIZE"
    echo "  cryptroot: $CRYPTROOT_SIZE (explicit)"

elif [ "$CONSTRAINT_BYTES" -lt "$TARGET_BYTES" ]; then
    # Target is not the smallest drive → limit cryptroot to fit the smaller one
    # ESP = 0.5 GiB, swap = 8 GiB → 8.5 GiB overhead
    FLOOR_GIB=$(python3 -c "
import math
usable = $CONSTRAINT_BYTES / 1024**3 - 8.5
usable = max(4, math.floor(usable))
print(usable)
" 2>/dev/null) || die "Failed to calculate cryptroot size"

    CRYPTROOT_SIZE="${FLOOR_GIB}G"
    echo "  📐 cryptroot: $CRYPTROOT_SIZE (limited to fit ${CONSTRAINT_GIB}G constraint drive)"
else
    CRYPTROOT_SIZE="100%"
    echo "  📐 cryptroot: 100% (target is the smallest drive)"
fi

# ═════════════════════════════════════════════════════════
#  Phase 5: Summary & confirmation
# ═════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════"
echo "  Target:   $TARGET_DEVICE"
echo "  Size:     ${TARGET_GIB}G"
echo "  cryptroot: $CRYPTROOT_SIZE"
echo ""
lsblk "$TARGET_DISK" -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null || true
echo ""

OTHER_DRIVES=()
for dev in "${ALL_DISKS[@]}"; do
    if [ "$(realpath "$dev")" = "$(realpath "$TARGET_DISK")" ]; then
        continue
    fi
    id=$(to_by_id "$dev")
    bytes=$(drive_bytes "$dev")
    gib=$(gib_from_bytes "$bytes")
    if has_ntfs "$dev"; then
        OTHER_DRIVES+=("  $id  (${gib}G, NTFS — kept untouched)")
    else
        OTHER_DRIVES+=("  $id  (${gib}G, candidate)")
    fi
done

if [ ${#OTHER_DRIVES[@]} -gt 0 ]; then
    echo "  Other drives:"
    for d in "${OTHER_DRIVES[@]}"; do
        echo "    $d"
    done
fi
echo "═══════════════════════════════════════════════"

if [ "$CRYPTROOT_SIZE" != "100%" ]; then
    echo ""
    echo "⚠️  cryptroot limited to $CRYPTROOT_SIZE"
    echo "   Future mirror members can be up to ${CONSTRAINT_GIB}G (the smallest drive)."
fi
echo ""
read -rp "⚠️  This will DESTROY ALL DATA on the target drive. Continue? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 2
fi

# ═════════════════════════════════════════════════════════
#  Phase 6: Build temporary disko config
# ═════════════════════════════════════════════════════════

DISKO_NIX=$(mktemp /tmp/disko-config.XXXXXX.nix) || die "Failed to create temp file"
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

# ═════════════════════════════════════════════════════════
#  Phase 7: Disko — partition, LUKS, ZFS
# ═════════════════════════════════════════════════════════

echo ""
echo "💿 Running disko (partition, LUKS encrypt, ZFS pool)..."
sudo nix run github:nix-community/disko -- --mode disko "$DISKO_NIX" \
    || die "disko failed — check the error above"

# Verify /mnt was created
if [ ! -d "/mnt" ] || [ ! -d "/mnt/nix" ]; then
    die "/mnt/nix does not exist — disko may not have mounted the pool"
fi

# ═════════════════════════════════════════════════════════
#  Phase 8: NixOS install
# ═════════════════════════════════════════════════════════

echo ""
echo "📦 Installing NixOS..."
sudo nixos-install --flake "$SCRIPT_DIR#p51" --root /mnt \
    || die "nixos-install failed"

# ═════════════════════════════════════════════════════════
#  Done
# ═════════════════════════════════════════════════════════

echo ""
echo "✅ Install complete!"
echo ""
echo "   Next steps:"
echo "   ─────────────────────────────────────────────"
echo "   1. Set your password:  sudo passwd liam"
echo "   2. Reboot:             sudo reboot"
echo "   ─────────────────────────────────────────────"
echo ""
echo "   After reboot, update hosts/p51/default.nix:"
echo "   - diskDevice = \"${TARGET_DEVICE}\""
if [ "$CRYPTROOT_SIZE" != "100%" ]; then
    echo "   - cryptrootSize = \"${CRYPTROOT_SIZE}\""
fi
