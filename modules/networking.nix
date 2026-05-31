{ lib, pkgs, ... }:

{
  # ── Hostname (set in hosts/p51/default.nix) ───────

  # ── Network manager ───────────────────────────────
  networking.networkmanager.enable = true;

  # ── Firewall ──────────────────────────────────────
  networking.firewall = {
    enable = true;
    allowPing = true;
    # allowedTCPPorts = [ ... ];
    # allowedUDPPorts = [ ... ];
  };

  # ── DNS ───────────────────────────────────────────
  services.resolved.enable = true;
  services.resolved.dnssec = "true";
}
