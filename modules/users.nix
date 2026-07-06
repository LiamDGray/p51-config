{ lib, pkgs, ... }:

{
  # ── User: liam ────────────────────────────────────
  users.users.liam = {
    isNormalUser = true;
    hashedPasswordFile = "/persist/etc/shadow-liam";
    extraGroups = [
      "wheel"
      "networkmanager"
      "input"
      "audio"
      "video"
      "bluetooth"
    ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      # Add your public SSH key(s) here
      # "ssh-ed25519 AAA..."
    ];
  };

  # ── Default shell ─────────────────────────────────
  programs.zsh.enable = true;
  environment.shells = with pkgs; [ zsh ];

  # ── Password-less sudo for wheel ──────────────────
  # Configured in core.nix via security.sudo.extraRules
}
