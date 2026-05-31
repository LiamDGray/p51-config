{ lib, pkgs, ... }:

{
  # ── SSH daemon ────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  # ── Misc system services ──────────────────────────
  services.fstrim.enable = true;               # NVMe TRIM
  services.udisks2.enable = true;               # Auto-mount removable media

  # ── Printing (optional) ──────────────────────────
  # services.printing.enable = lib.mkDefault false;

  # ── Sound (ALSA/PipeWire) ────────────────────────
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = false;
  };

  # ── Bluetooth ────────────────────────────────────
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
}
