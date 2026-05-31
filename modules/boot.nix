{ lib, pkgs, ... }:

{
  # ── Bootloader: systemd-boot ──────────────────────
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;      # Keep last 10 generations
      editor = false;                # Disable kernel param editing at boot
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot";
    };
    # Timeout: 5 seconds to pick a generation
    timeout = 5;
  };

  # ── Kernel ────────────────────────────────────────
  # linuxPackages_latest is set in hardware.nix as default.
  # For ZFS compatibility, pin to the default kernel if latest lags.
  boot.kernelParams = [
    "quiet"                           # Less boot spam
    "splash"                          # Plymouth splash
    "mitigations=off"                 # Performance over Spectre/Meltdown protection
  ];

  # ── Plymouth (boot splash) ────────────────────────
  boot.plymouth.enable = true;
}
