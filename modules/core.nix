{ lib, pkgs, ... }:

{
  # ── Nix settings ──────────────────────────────────
  nix = {
    settings = {
      auto-optimise-store = true;
      experimental-features = ["nix-command" "flakes"];
      warn-dirty = false;
      trusted-users = ["@wheel"];
    };
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 7d";
    };
    # Deduplicate and optimise after each build
    optimise.automatic = true;
  };

  # ── Locale & time ─────────────────────────────────
  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "America/Phoenix"; # Arizona = MST year-round

  # ── Console font ──────────────────────────────────
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # ── ZFS ───────────────────────────────────────────
  # Auto-enabled by disko when a zpool is defined — no need to set
  # boot.zfs.enabled manually.

  # ZFS packages available in system PATH
  environment.systemPackages = with pkgs; [
    zfs
  ];

  # ── Security ──────────────────────────────────────
  security.sudo.extraRules = [
    {
      groups = ["wheel"];
      commands = [
        {
          command = "ALL";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # ── LUKS initrd support ──────────────────────────
  boot.initrd = {
    supportedFilesystems = ["zfs"];
    systemd.enable = true;
  };

  # nixos-hardware's thinkpad-p51 module enables hardware.enableAllFirmware
  nixpkgs.config.allowUnfree = true;
}
