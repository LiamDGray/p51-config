#!/usr/bin/env bash
# install.sh — Install NixOS on a ThinkPad P51 via nixos-anywhere
#
# Detects the correct NVMe drive (skips NTFS), calculates a mirror-safe
# cryptroot size, then delegates to nixos-anywhere for the install.
# nixos-anywhere handles networking inside the chroot, retries on
# disko failure, and post-install file population.
#
# Usage:
#   sudo ./install.sh                              # auto-detect
#   sudo ./install.sh /dev/nvme0n1                 # explicit
#   sudo ./install.sh /dev/disk/by-id/nvme-XXX     # explicit

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ═════════════════════════════════════════════════════════
#  Guard: prerequisites
# ═════════════════════════════════════════════════════════

MISSING=""
for cmd in lsblk readlink basename realpath python3 nix sudo mkpasswd; do
    command -v "$cmd" &>/dev/null || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
    echo "❌ Missing required tools:$MISSING"
    echo "   On the NixOS live USB, run: nix-shell -p python3 mkpasswd"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Must be run as root"
    exit 1
fi
if [ ! -f "${SCRIPT_DIR}/hosts/p51/disko-config.nix" ]; then
    echo "❌ Cannot find disko config at ${SCRIPT_DIR}/hosts/p51/disko-config.nix"
    echo "   Make sure you're running install.sh from the p51-config directory"
    exit 1
fi

# ═════════════════════════════════════════════════════════
#  Helpers
# ═════════════════════════════════════════════════════════

die() { echo "❌ $*" >&2; exit 1; }

gib_from_bytes() {
    python3 -c "import math; print(math.floor($1 / 1024**3))"
}

to_by_id() {
    local dev="$1"
    local real_disk
    real_disk=$(realpath "$dev" 2>/dev/null)
    if [ -z "$real_disk" ] || [ ! -b "$real_disk" ]; then
        echo "$dev"
        return
    fi
    local best_eui=""
    for link in /dev/disk/by-id/nvme-*; do
        [ -L "$link" ] || continue
        local target
        target=$(readlink -f "$link" 2>/dev/null) || continue
        if [ "$target" = "$real_disk" ]; then
            if [[ "$(basename "$link")" != nvme-eui.* ]]; then
                echo "$link"
                return
            fi
            [ -z "$best_eui" ] && best_eui="$link"
        fi
    done
    [ -n "$best_eui" ] && echo "$best_eui" || echo "$dev"
}

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

has_ntfs() {
    local dev="$1"
    local cnt
    cnt=$(lsblk "$dev" -n -o FSTYPE 2>/dev/null | grep -c -i "ntfs" 2>/dev/null) || true
    [ "$cnt" -gt 0 ]
}

drive_bytes() {
    local val
    val=$(lsblk -d -b -n -o SIZE "$1" 2>/dev/null) || true
    [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null && echo "$val" || echo "0"
}

# ═════════════════════════════════════════════════════════
#  Drive inventory display
# ═════════════════════════════════════════════════════════

show_drive_inventory() {
    local smallest_bytes=9999999999999999
    local smallest_dev=""

    for dev in "${ALL_DISKS[@]}"; do
        local bytes
        bytes=$(drive_bytes "$dev")
        [ "$bytes" -lt "$smallest_bytes" ] && { smallest_bytes=$bytes; smallest_dev="$dev"; }
    done

    echo ""
    echo "┌─ NVMe Drive Inventory ─────────────────────────────────────────────────────┐"
    printf "│ %-12s %7s  %-30s %-5s %s │\n" "DEVICE" "SIZE" "MODEL" "NTFS?" "PARTITIONS"
    echo "├────────────────────────────────────────────────────────────────────────────┤"

    for dev in "${ALL_DISKS[@]}"; do
        local name size_gib model ntfs parts note
        name=$(basename "$dev")
        size_gib=$(gib_from_bytes "$(drive_bytes "$dev")")G
        model=$(lsblk -d -n -o MODEL "$dev" 2>/dev/null | head -c 28)
        has_ntfs "$dev" && ntfs="YES" || ntfs="no"

        # Build partition summary (list child partitions and their fstypes)
        parts=""
        while IFS= read -r line; do
            local pname pfstype
            pname=$(echo "$line" | awk '{print $1}')
            pfstype=$(echo "$line" | awk '{print $2}')
            pname="${pname#$name}"
            [ -n "$parts" ] && parts="$parts, "
            parts="${parts}${pname}:${pfstype:-?}"
        done < <(lsblk "$dev" -n -o NAME,FSTYPE 2>/dev/null | grep -v "^$name ")
        [ -z "$parts" ] && parts="(blank)"

        note=""
        [ "$dev" = "$smallest_dev" ] && note=" ← smallest"

        printf "│ %-12s %6s  %-30s %-5s %s%s │\n" "/dev/$name" "$size_gib" "$model" "$ntfs" "$parts" "$note"
    done
    echo "└────────────────────────────────────────────────────────────────────────────┘"

    if [ -n "$smallest_dev" ]; then
        local smallest_gib safe_max
        smallest_gib=$(gib_from_bytes "$smallest_bytes")
        safe_max=$((smallest_gib - 9))
        echo ""
        echo "  Smallest: $(basename "$smallest_dev") (${smallest_gib}G) → mirror-safe cryptroot ≤ ${safe_max}G"
        echo "  (${smallest_gib}G − 0.5G ESP − 8G swap − rounding)"
        echo ""
    fi
}

# ═════════════════════════════════════════════════════════
#  Force-wipe helpers
# ═════════════════════════════════════════════════════════

force_wipe() {
    local disk="$1"
    local name
    name=$(basename "$disk")
    echo "⚠️  --force: wiping existing data on $name..."

    # Destroy any ZFS pool on partitions of this disk
    for pool in $(zpool list -H -o name 2>/dev/null || true); do
        if zpool status -P "$pool" 2>/dev/null | grep -qP "/dev/${name}p?\d+"; then
            echo "  Destroying ZFS pool: $pool"
            zpool destroy "$pool" || true
        fi
    done

    # Close LUKS containers backed by this disk
    for mapper in cryptroot cryptswap; do
        if [ -e "/dev/mapper/$mapper" ]; then
            local src
            src=$(cryptsetup status "$mapper" 2>/dev/null | grep "device:" | awk '{print $2}')
            if echo "$src" | grep -q "$name"; then
                echo "  Closing LUKS: $mapper"
                cryptsetup close "$mapper" || true
            fi
        fi
    done

    # Wipe partition table and all filesystem signatures
    echo "  Wiping partition table and filesystem signatures..."
    wipefs -a "$disk"
    echo "  ✅ Target disk wiped."
}

# ═════════════════════════════════════════════════════════
#  SSH setup for local nixos-anywhere
# ═════════════════════════════════════════════════════════

setup_local_ssh() {
    # Ensure sshd is running
    if ! systemctl is-active --quiet sshd 2>/dev/null; then
        echo "  Starting sshd..."
        systemctl start sshd
    fi

    # Generate a throwaway SSH key for the local install
    SSH_KEY="/tmp/nixos-anywhere-key"
    if [ ! -f "$SSH_KEY" ]; then
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    fi

    # Authorize it to root's authorized_keys
    mkdir -p ~root/.ssh
    cat "$SSH_KEY.pub" >> ~root/.ssh/authorized_keys
    chmod 600 ~root/.ssh/authorized_keys
}

# ═════════════════════════════════════════════════════════
#  Phase 1: Parse arguments
# ═════════════════════════════════════════════════════════

ARG_DEVICE=""
ARG_CRYPTROOT_SIZE=""
ARG_FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cryptroot-size)
            [ $# -lt 2 ] && die "--cryptroot-size requires an argument (e.g. '230G')"
            ARG_CRYPTROOT_SIZE="$2"
            shift 2
            ;;
        --force|-f)
            ARG_FORCE=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [device] [--cryptroot-size SIZE] [--force]"
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            [ -n "$ARG_DEVICE" ] && die "Unexpected extra argument: $1"
            ARG_DEVICE="$1"
            shift
            ;;
    esac
done

# ═════════════════════════════════════════════════════════
#  Phase 2: Discover NVMe drives
# ═════════════════════════════════════════════════════════

echo "🔍 Scanning NVMe drives..."

ALL_DISKS=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    dev="/dev/$line"
    [ -b "$dev" ] && ALL_DISKS+=("$(realpath "$dev")")
done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '/disk/ && /nvme/ {print $1}' || true)

NTFS_DISKS=()
CANDIDATE_DISKS=()
for dev in "${ALL_DISKS[@]}"; do
    has_ntfs "$dev" && NTFS_DISKS+=("$dev") || CANDIDATE_DISKS+=("$dev")
done

# ── Show drive inventory ──────────────────────────────
show_drive_inventory

# ═════════════════════════════════════════════════════════
#  Phase 3: Select target drive
# ═════════════════════════════════════════════════════════

TARGET_DEVICE=""
TARGET_DISK=""

if [ -n "$ARG_DEVICE" ]; then
    TARGET_DEVICE=$(to_by_id "$ARG_DEVICE")
    TARGET_DISK=$(to_disk_device "$ARG_DEVICE")
    [ -z "$TARGET_DISK" ] && die "Device does not exist or is not a block device: $ARG_DEVICE"
    echo "  Explicit target: $TARGET_DEVICE"

elif [ ${#CANDIDATE_DISKS[@]} -eq 0 ]; then
    if [ ${#NTFS_DISKS[@]} -gt 0 ]; then
        die "All NVMe drives have NTFS partitions. Cannot determine target."
    elif [ ${#ALL_DISKS[@]} -eq 0 ]; then
        die "No NVMe drives found. Pass the device path explicitly."
    else
        die "No suitable target — lsblk isn't reporting filesystem info. Pass device path explicitly."
    fi

elif [ ${#CANDIDATE_DISKS[@]} -eq 1 ]; then
    TARGET_DISK="${CANDIDATE_DISKS[0]}"
    TARGET_DEVICE=$(to_by_id "$TARGET_DISK")
    echo "  Auto-selected: $TARGET_DEVICE"

else
    echo "⚠️  Multiple NVMe drives found without NTFS."
    for dev in "${CANDIDATE_DISKS[@]}"; do
        id=$(to_by_id "$dev")
        bytes=$(drive_bytes "$dev")
        gib=$(gib_from_bytes "$bytes")
        echo "    $id  (${gib}G)"
    done
    exit 1
fi

if [ -z "$TARGET_DISK" ]; then
    TARGET_DISK=$(to_disk_device "$TARGET_DEVICE")
fi
if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    die "Target $TARGET_DEVICE cannot be resolved"
fi
if [[ "$(basename "$TARGET_DISK")" != nvme* ]]; then
    die "Target $TARGET_DEVICE ($TARGET_DISK) does not appear to be an NVMe drive"
fi

TARGET_BYTES=$(drive_bytes "$TARGET_DISK")
[ "$TARGET_BYTES" -le 0 ] && die "Cannot read size of $TARGET_DISK"
TARGET_GIB=$(gib_from_bytes "$TARGET_BYTES")

# ═════════════════════════════════════════════════════════
#  Phase 4: Calculate cryptroot size
# ═════════════════════════════════════════════════════════

CONSTRAINT_BYTES=$TARGET_BYTES
for ntfs_dev in "${NTFS_DISKS[@]}"; do
    ntfs_bytes=$(drive_bytes "$ntfs_dev")
    [ "$ntfs_bytes" -gt 0 ] && [ "$ntfs_bytes" -lt "$CONSTRAINT_BYTES" ] && CONSTRAINT_BYTES=$ntfs_bytes
done
for other_dev in "${CANDIDATE_DISKS[@]}"; do
    [ "$(realpath "$other_dev")" = "$(realpath "$TARGET_DISK")" ] && continue
    other_bytes=$(drive_bytes "$other_dev")
    [ "$other_bytes" -gt 0 ] && [ "$other_bytes" -lt "$CONSTRAINT_BYTES" ] && CONSTRAINT_BYTES=$other_bytes
done
CONSTRAINT_GIB=$(gib_from_bytes "$CONSTRAINT_BYTES")

if [ -n "$ARG_CRYPTROOT_SIZE" ]; then
    CRYPTROOT_SIZE="$ARG_CRYPTROOT_SIZE"
elif [ "$CONSTRAINT_BYTES" -lt "$TARGET_BYTES" ]; then
    FLOOR_GIB=$(python3 -c "
import math
usable = $CONSTRAINT_BYTES / 1024**3 - 8.5
usable = max(4, math.floor(usable))
print(usable)
" 2>/dev/null) || die "Failed to calculate cryptroot size"
    CRYPTROOT_SIZE="${FLOOR_GIB}G"
else
    CRYPTROOT_SIZE="100%"
fi

# ═════════════════════════════════════════════════════════
#  Phase 5: Summary & confirmation
# ═════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════"
echo "  Target:   $TARGET_DEVICE  (${TARGET_GIB}G)"
echo "  cryptroot: $CRYPTROOT_SIZE"
echo ""
lsblk "$TARGET_DISK" -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null || true
echo ""
OTHER_DRIVES=()
for dev in "${ALL_DISKS[@]}"; do
    [ "$(realpath "$dev")" = "$(realpath "$TARGET_DISK")" ] && continue
    id=$(to_by_id "$dev")
    bytes=$(drive_bytes "$dev")
    gib=$(gib_from_bytes "$bytes")
    has_ntfs "$dev" \
        && OTHER_DRIVES+=("  $id  (${gib}G, NTFS — kept untouched)") \
        || OTHER_DRIVES+=("  $id  (${gib}G, candidate)")
done
[ ${#OTHER_DRIVES[@]} -gt 0 ] && echo "  Other drives:" && for d in "${OTHER_DRIVES[@]}"; do echo "    $d"; done

# Mirror compatibility note
if [ "$CRYPTROOT_SIZE" != "100%" ]; then
    echo "  ───────────────────────────────────────────────"
    echo "  ⚠️  cryptroot limited to $CRYPTROOT_SIZE"
    echo "     (mirror-friendly — fits on smallest ${CONSTRAINT_GIB}G drive)"
else
    echo "  ───────────────────────────────────────────────"
    echo "  💡 cryptroot uses 100% of remaining space"
    if [ "${#NTFS_DISKS[@]}" -gt 0 ] || [ "${#CANDIDATE_DISKS[@]}" -gt 1 ]; then
        echo "     To mirror to a smaller drive later, re-run with:"
        echo "     --cryptroot-size <size>G"
    fi
fi
echo "═══════════════════════════════════════════════"
echo ""
read -rp "⚠️  This will DESTROY ALL DATA on the target. Continue? [y/N] " CONFIRM
[ "$CONFIRM" != "y" ] && { echo "Aborted."; exit 2; }

# Prompt for liam's password
echo ""
while true; do
    read -rs -p "Enter new password for user 'liam': " LIAM_PASS
    echo
    read -rs -p "Retype new password: " LIAM_PASS2
    echo
    if [ "$LIAM_PASS" = "$LIAM_PASS2" ]; then
        if [ -n "$LIAM_PASS" ]; then
            break
        else
            echo "❌ Password cannot be empty."
        fi
    else
        echo "❌ Passwords do not match. Try again."
    fi
done

# ═════════════════════════════════════════════════════════
#  Phase 5b: Force-wipe target (if --force)
# ═════════════════════════════════════════════════════════

if [ "$ARG_FORCE" -eq 1 ]; then
    force_wipe "$TARGET_DISK"
fi

# ═════════════════════════════════════════════════════════
#  Phase 5c: Set up local SSH for nixos-anywhere
# ═════════════════════════════════════════════════════════

setup_local_ssh

# ═════════════════════════════════════════════════════════
#  Phase 6: Build temp flake with overridden device path
#  nixos-anywhere reads the disko config from the flake,
#  so we create a copy of our flake with the correct
#  diskDevice and cryptrootSize baked into default.nix.
# ═════════════════════════════════════════════════════════

TMP_FLAKE=$(mktemp -d /tmp/install-flake.XXXXXX) || die "Failed to create temp flake dir"
cleanup() { rm -rf "$TMP_FLAKE" "$EXTRA_DIR"; }
trap cleanup EXIT

# Copy the entire flake tree (it's small — ~15 files)
cp -a "$SCRIPT_DIR"/flake.nix "$SCRIPT_DIR"/flake.lock "$TMP_FLAKE/"
cp -a "$SCRIPT_DIR"/hosts "$TMP_FLAKE/hosts"
cp -a "$SCRIPT_DIR"/modules "$TMP_FLAKE/modules"

# Rewrite default.nix with the correct device and size
cat > "$TMP_FLAKE/hosts/p51/default.nix" << FLAKE_NIX
{ lib, pkgs, disko, impermanence, ... }:
{
  imports = [
    (import ./disko-config.nix {
      diskDevice = "${TARGET_DEVICE}";
      cryptrootSize = "${CRYPTROOT_SIZE}";
    })
    ./hardware.nix
    ../../modules/core.nix
    ../../modules/boot.nix
    ../../modules/networking.nix
    ../../modules/services.nix
    ../../modules/users.nix
    ../../modules/impermanence.nix
    ../../modules/backups.nix
  ];
  networking.hostName = "p51";
  networking.hostId = "deadbeef";
  system.stateVersion = "24.11";
}
FLAKE_NIX

# ═════════════════════════════════════════════════════════
#  Phase 7: Build extra-files for first boot
#  nixos-anywhere copies these into the new root.
#  Impermanence will bind-mount /persist/... paths on boot.
# ═════════════════════════════════════════════════════════

EXTRA_DIR=$(mktemp -d /tmp/extra-files.XXXXXX) || die "Failed to create extra-files dir"

# SSH host keys (persisted)
mkdir -p "$EXTRA_DIR/persist/etc/ssh"
if command -v ssh-keygen &>/dev/null; then
    ssh-keygen -t ed25519 -f "$EXTRA_DIR/persist/etc/ssh/ssh_host_ed25519_key" -N "" -q
    ssh-keygen -t rsa -b 4096 -f "$EXTRA_DIR/persist/etc/ssh/ssh_host_rsa_key" -N "" -q
    echo "  🔑 Generated SSH host keys in extra-files"
fi

# /etc/machine-id (persisted)
mkdir -p "$EXTRA_DIR/persist/etc"
if command -v uuidgen &>/dev/null; then
    uuidgen | md5sum | cut -d' ' -f1 > "$EXTRA_DIR/persist/etc/machine-id"
    echo "  🆔 Generated machine-id in extra-files"
fi

# /etc/NetworkManager connections directory
mkdir -p "$EXTRA_DIR/persist/etc/NetworkManager/system-connections"

# Password hash for liam
printf '%s' "$LIAM_PASS" | mkpasswd -m sha-512 > "$EXTRA_DIR/persist/etc/shadow-liam"
chmod 600 "$EXTRA_DIR/persist/etc/shadow-liam"
echo "  🔑 Generated password hash in extra-files"

# User home skeleton
mkdir -p "$EXTRA_DIR/persist/home/liam/.ssh"
chmod 700 "$EXTRA_DIR/persist/home/liam/.ssh"

# ═════════════════════════════════════════════════════════
#  Phase 8: Run nixos-anywhere
# ═════════════════════════════════════════════════════════

echo ""
echo "💿 Running nixos-anywhere (partition → install → first-boot files)..."
echo ""

# Enable flakes/nix-command for the nix invocation
NIX_CONFIG=$'experimental-features = nix-command flakes\naccept-flake-config = true'
export NIX_CONFIG

sudo NIX_CONFIG="$NIX_CONFIG" nix run github:nix-community/nixos-anywhere -- \
    --flake "$TMP_FLAKE#p51" \
    --extra-files "$EXTRA_DIR" \
    -i "$SSH_KEY" \
    --target-host root@localhost \
    --phases disko,install \
    2>&1 || die "nixos-anywhere failed"

echo ""
echo "✅ Install complete!"
echo ""
echo "   Next steps:"
echo "   ─────────────────────────────────────────────"
echo "   1. Reboot:  sudo reboot"
echo "   ─────────────────────────────────────────────"
echo ""
echo "   📝 After reboot, update the real hosts/p51/default.nix:"
echo "      diskDevice = \"${TARGET_DEVICE}\""
[ "$CRYPTROOT_SIZE" != "100%" ] && echo "      cryptrootSize = \"${CRYPTROOT_SIZE}\""
