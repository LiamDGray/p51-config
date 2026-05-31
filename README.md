# p51-config — NixOS for ThinkPad P51

**ZFS + LUKS + impermanence**

## Partition layout

```
nvme0n1 (1 TB, later RAID 1 via zpool attach)
├── p1  ESP         512 MB  FAT32    /boot           — UEFI, unencrypted
├── p2  cryptswap    8 GB   LUKS2   /dev/mapper/…   — random key, no resume
└── p3  cryptroot   ~992 GB LUKS2   zroot (ZFS)     — everything else

zroot (compression=lz4, atime=off)
├── safe                      — container for auto-snapshotted datasets
│   ├── safe/nix       → /nix        — Nix store (persistent)
│   ├── safe/persist   → /persist    — impermanence backing store
│   ├── safe/log       → /var/log    — persistent logs
│   └── safe/cache     → /var/cache  — persistent caches
```

## Pre-install (on live USB)

```bash
# 1. Boot NixOS minimal ISO, get internet
iwctl station wlan0 connect "SSID"

# 2. Clone this config
nix shell nixpkgs#git -c git clone https://github.com/your-org/p51-config
cd p51-config

# 3. Identify your disk
lsblk -o NAME,SIZE,MODEL,SERIAL

# 4. Update the disk device in hosts/p51/default.nix
#    Set diskDevice to your NVMe by-id path, e.g.:
#      diskDevice = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_SERIAL";

# 5. Run disko — partitions, LUKS, ZFS pool, all datasets
sudo nix run github:nix-community/disko -- --flake .#p51

# 6. Install
sudo nixos-install --flake .#p51
```

## Post-install

```bash
# Set user password (user 'liam' created without one)
sudo passwd liam

# Reboot into your new system
sudo reboot
```

## Adding a second NVMe (RAID 1 mirror)

1. Install the second drive
2. `lsblk` to identify it
3. Partition it with the same GPT layout (ESP + LUKS)
4. `zpool attach zroot /dev/disk/by-id/<nvme0-cryptroot> /dev/disk/by-id/<nvme1-cryptroot>`
5. Uncomment the `nvme1` disk block in `hosts/p51/disko-config.nix`
6. Set `disk.mode = "mirror"` in the zpool config
7. Update and rebuild: `sudo nixos-rebuild switch`

## Setting the LUKS password

During step 5 (disko), you'll be prompted for the LUKS password. Choose a strong one — it unlocks `cryptroot` on every boot.

## Customizing

| File | What to change |
|---|---|
| `hosts/p51/disko-config.nix` | Partition sizes, ZFS dataset layout |
| `hosts/p51/hardware.nix` | GPU driver, kernel version, modules |
| `modules/users.nix` | SSH keys, extra users |
| `modules/impermanence.nix` | Which paths survive reboots |
| `modules/networking.nix` | Firewall rules, DNS |
| `modules/services.nix` | Enabled system services |
