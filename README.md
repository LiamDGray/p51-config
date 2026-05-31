# p51-config — NixOS for ThinkPad P51

**ZFS + LUKS + impermanence**

## Partition layout (on the target drive)

```
nvmeZnZ (target drive — smaller of the two)
├── p1  ESP         512 MB  FAT32    /boot           — UEFI, unencrypted
├── p2  cryptswap    8 GB   LUKS2   /dev/mapper/…   — random key, no resume
└── p3  cryptroot   rest    LUKS2   zroot (ZFS)     — everything else

zroot (compression=lz4, atime=off)
├── safe                      — container for auto-snapshotted datasets
│   ├── safe/nix       → /nix        — Nix store (persistent)
│   ├── safe/persist   → /persist    — impermanence backing store
│   ├── safe/log       → /var/log    — persistent logs
│   └── safe/cache     → /var/cache  — persistent caches
```

**The root partition adapts to your drive.** `cryptroot` is set to `"100%"` of remaining space after ESP (512M) and swap (8G). Whichever drive you pick, it fills the space available, so the smaller drive is never a problem.

## Drive selection — safety

The P51 has **two NVMe drives**. The install script (`install.sh`) forces you to pick one explicitly — it will **never** touch a drive you don't name.

```bash
# Boot NixOS live USB
# Get internet (if using git)
iwctl station wlan0 connect "SSID"

# Identify BOTH drives
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE

# You'll see something like:
# nvme0n1  256G SAMSUNG MZVLB256 ...  ← your existing system drive
# nvme1n1  512G SAMSUNG MZVLB512 ...  ← acceptable target (smaller)

# Pick the small one. Then:
```

### Getting the config onto the live system

**Option A — second USB stick** (no internet needed)
```bash
# On the T430s:
cp -r /home/liam/src/p51-config /path/to/usb/

# On the P51 live USB:
mount /dev/sdb1 /mnt/usb
cd /mnt/usb/p51-config
```

**Option B — internet** (push to a git host first)
```bash
nix-shell -p git
git clone <url> p51-config
cd p51-config
```

### Install

```bash
# (optional) Check both drives — note the smaller one's capacity
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
# Smaller drive shows e.g. 476.9G → cryptroot can be at most ~468G

# Run the install script with YOUR chosen device
# Without size limit (will use 100% of this drive):
sudo ./install.sh /dev/disk/by-id/nvme-SAMSUNG_MZVLB512_XXXXXXXX

# WITH size limit (ensures mirror fits on a smaller drive later):
sudo ./install.sh /dev/disk/by-id/nvme-SAMSUNG_MZVLB1T_XXXXXXXX --cryptroot-size 468G

# The script will:
#   1. Show you the drive and ask for confirmation
#   2. Run disko (partition, LUKS encrypt, ZFS pool)
#   3. Install NixOS
#   4. Tell you to set a password and reboot
```

### Calculating `--cryptroot-size` for future mirror compatibility

```
smaller_drive_raw_gib - 0.5G (ESP) - 8G (swap) = safe cryptroot size

Example: 512GB drive → 476.9 - 0.5 - 8 ≈ 468G
Example: 256GB drive → 238.5 - 0.5 - 8 ≈ 230G
```

If the target drive is **bigger** than the other drive, you **must** use `--cryptroot-size` so the partitions fit on both. If they're the same size, you can omit it (defaults to `"100%"`).

### After install

Update `hosts/p51/default.nix` to:
- Set `diskDevice` to the actual device path
- Set `cryptrootSize` to match what you used (or leave unset if `"100%"`)

```bash
# Set user password (user 'liam' created without one)
sudo passwd liam

# Reboot into your new system — disconnect the live USB
sudo reboot
```

## Adding a second NVMe (RAID 1 mirror)

When you add a drive to mirror to:

1. Boot the installed system
2. `lsblk` to identify the new drive
3. Partition it manually or with a one-shot disko run for that drive
4. `zpool attach zroot /dev/disk/by-id/<current-cryptroot> /dev/disk/by-id/<new-cryptroot>`

The ESP on the second drive can be kept as a manual backup — just copy the boot files after the mirror is set up.

## Customizing

| File | What to change |
|---|---|
| `hosts/p51/disko-config.nix` | Partition sizes, ZFS dataset layout |
| `hosts/p51/hardware.nix` | GPU driver, kernel version, modules |
| `hosts/p51/default.nix` | Device path (after install), hostId |
| `modules/users.nix` | SSH keys, extra users |
| `modules/impermanence.nix` | Which paths survive reboots |
| `modules/networking.nix` | Firewall rules, DNS |
| `modules/services.nix` | Enabled system services |

**⚠️ The install script (`install.sh`) injects the device path at runtime.**  
You don't need to edit `hosts/p51/default.nix` before installing.  
The device path in `default.nix` is only used for `nixos-rebuild` after installation — update it then if needed.
