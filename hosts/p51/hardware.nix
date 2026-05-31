# ThinkPad P51 — hardware-specific settings.
#
# Auto-generated hardware-configuration.nix equivalents.
# Run `nixos-generate-config --root /mnt` on the actual machine and
# merge anything extra from the generated file into this module.

{ config, lib, pkgs, ... }:

{
  imports = [
    # nixos-hardware thinkpad-p51 is loaded upstream in flake.nix
  ];

  # ── Kernel & modules ──────────────────────────────
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod"
    "rtsx_pci_sdmmc" "thunderbolt"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [];

  # ── CPU microcode ──────────────────────────────────
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;

  # ── GPU: Intel HD 630 (i915) + NVIDIA Quadro ──────
  # The P51 has both Intel integrated and NVIDIA discrete.
  # Options (pick one):
  #
  #   (1) Intel only — saves battery, fine for desktop
  #   (2) NVIDIA only (proprietary) — CUDA, external monitors
  #   (3) PRIME offload / Optimus — dynamic switching
  #
  # Default to Intel-only for reliability. Uncomment
  # `hardware.nvidia` below to enable the NVIDIA driver.
  services.xserver.videoDrivers = [ "modesetting" ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # VA-API for Intel
      intel-vaapi-driver
    ];
  };

  # hardware.nvidia = {
  #   modesetting.enable = true;
  #   prime = {
  #     intelBusId  = "PCI:0:2:0";
  #     nvidiaBusId = "PCI:1:0:0";
  #   };
  # };

  # ── Firmware ───────────────────────────────────────
  hardware.enableRedistributableFirmware = true;
}
