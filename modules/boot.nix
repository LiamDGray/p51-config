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
  boot.kernelParams = [
    "quiet"                           # Less boot spam
    "splash"                          # Plymouth splash
    "mitigations=off"                 # Performance over Spectre/Meltdown protection
  ];

  # ── Plymouth (boot splash) ────────────────────────
  boot.plymouth.enable = true;

  # ── cryptswap: random key on every boot ──────────
  # The LUKS was formatted with a one-time key during install.
  # At boot, initrd uses /dev/urandom to derive a fresh key,
  # making swap contents irrecoverable across reboots.
  boot.initrd.luks.devices.cryptswap = {
    keyFile = "/dev/urandom";
    allowDiscards = true;
  };
}
