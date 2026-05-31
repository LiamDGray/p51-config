{ lib, pkgs, disko, impermanence, ... }:

{
  imports = [
    # Import disko config with the P51's disk device path.
    # ⚠️ Update the disk by-id path before first install.
    (import ./disko-config.nix {
      diskDevice = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB";
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
  networking.hostId = "deadbeef"; # ZFS requires exactly 8 hex chars — change this
  system.stateVersion = "24.11";
}
