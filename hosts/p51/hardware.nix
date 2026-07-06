# ThinkPad P51 — hardware-specific settings.
#
# nixos-hardware's thinkpad-p51 module is loaded upstream in flake.nix
# and handles NVIDIA PRIME Optimus (Intel + Quadro), CPU microcode (Kaby
# Lake), WiFi firmware, and CPU throttling fix (throttled).
#
# This file adds P51 quirks that nixos-hardware doesn't cover.

{ config, lib, pkgs, ... }:

{
  imports = [
    # nixos-hardware thinkpad-p51 is loaded upstream in flake.nix
    # It handles NVIDIA PRIME, CPU, WiFi firmware, and throttled.
    #
    # We do NOT override services.xserver.videoDrivers here —
    # nixos-hardware sets it correctly for NVIDIA PRIME sync.
  ];

  # ── Kernel & modules ──────────────────────────────
  # ZFS 2.2.x in nixos-24.11 doesn't support the latest kernel.
  # We use the default stable kernel for compatibility.
  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod"
    "rtsx_pci_sdmmc" "thunderbolt"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [];

  # ── CPU microcode ──────────────────────────────────
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;

  # ── GPU acceleration (Intel side) ─────────────────
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # VA-API for Intel
      intel-vaapi-driver
    ];
  };

  # ── Fingerprint reader ────────────────────────────
  # P51 has a Synaptics FS7604 or similar.
  services.fprintd.enable = true;

  # ── TrackPoint / libinput ─────────────────────────
  services.libinput.enable = true;

  # ── Firmware ───────────────────────────────────────
  hardware.enableRedistributableFirmware = true;
}
