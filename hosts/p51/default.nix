{ lib, pkgs, disko, impermanence, ... }:

{
  imports = [
    # ═══════════════════════════════════════════════════════════
    #  IMPORTANT: Set the correct disk device for your P51.
    #
    #  If you're installing fresh from a live USB, use install.sh
    #  which overrides this automatically.
    #
    #  If you're rebuilding after install (nixos-rebuild switch),
    #  update this to your actual NVMe by-id path.
    #
    #  Find it with: lsblk -o NAME,SIZE,MODEL,SERIAL
    # ═══════════════════════════════════════════════════════════
    (import ./disko-config.nix {
      # ⚠️  REPLACE THIS with your NVMe device by-id
      diskDevice = "/dev/disk/by-id/nvme-CHANGE_THIS_TO_YOUR_DRIVE";
    })
    ./hardware.nix

    ../../modules/core.nix
    ../../modules/boot.nix
    ../../modules/networking.nix
    ../../modules/services.nix
    ../../modules/users.nix
    ../../modules/impermanence.nix
  ];

  # ── Hostname ───────────────────────────────────────
  networking.hostName = "p51";
  # ZFS hostId — exactly 8 hex chars. Change to a unique value.
  # Generate with: od -A n -t x -N 4 /dev/urandom | tr -d ' '
  networking.hostId = "deadbeef";
  system.stateVersion = "24.11";
}
