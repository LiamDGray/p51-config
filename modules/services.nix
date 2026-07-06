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

  # ── Power management ──────────────────────────────
  services.tlp = {
    enable = true;
    settings = {
      # P51 has two batteries: BAT0 (internal 32 Wh) + BAT1 (external 70 Wh).
      # Charge thresholds prevent bloat on always-plugged desk use.
      START_CHARGE_THRESH_BAT0 = 75;
      STOP_CHARGE_THRESH_BAT0  = 85;
      START_CHARGE_THRESH_BAT1 = 75;
      STOP_CHARGE_THRESH_BAT1  = 85;

      # CPU frequency scaling governor
      CPU_SCALING_GOVERNOR_ON_AC  = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

      # NVMe power saving
      NVMEPOWER_ON_AC  = 0;
      NVMEPOWER_ON_BAT = 4;

      # SATA power saving
      SATA_LINKPWR_ON_AC  = "med_power_with_dipm";
      SATA_LINKPWR_ON_BAT = "med_power_with_dipm";
    };
  };

  # ── Thunderbolt hotplug ───────────────────────────
  services.hardware.bolt.enable = true;

  # ── Lid close ──────────────────────────────────────
  services.logind.lidSwitch = "suspend";
}
