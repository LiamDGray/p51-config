{ lib, pkgs, ... }:

{
  # ── X server ─────────────────────────────────────
  services.xserver.enable = true;

  # ── Xfce Desktop ─────────────────────────────────
  services.xserver.desktopManager.xfce.enable = true;
  services.xserver.desktopManager.xfce.noDesktop = false;
  services.xserver.desktopManager.xfce.enableXfwm = true;

  services.xserver.displayManager.lightdm.enable = true;

  programs.thunar.enable = true;
  programs.thunar.plugins = with pkgs.xfce; [
    thunar-archive-plugin
    thunar-volman
  ];

  services.gvfs.enable = true;         # Trash, mounting, GVFS
  services.tumbler.enable = true;      # Thumbnail previews

  # ── Fonts ────────────────────────────────────────
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-emoji
    liberation_ttf
    dejavu_fonts
  ];

  # ── HiDPI scaling (uncomment for 4K panel) ───────
  # The P51 shipped with 1080p, 4K, or 4K OLED.
  # Set DPI to match your panel:
  #   96   → 1080p
  #   192  → 4K / UHD (3840×2160)
  # services.xserver.dpi = 192;

  # ── Xfce defaults ────────────────────────────────
  environment.sessionVariables = {
    # Ensure Xfce uses the correct GTK theme
    GTK_THEME = "Adwaita";
  };

  # ── Useful desktop packages ──────────────────────
  environment.systemPackages = with pkgs; [
    firefox
    xfce.xfce4-terminal
    xfce.parole            # Media player
    xfce.ristretto         # Image viewer
    xfce.mousepad          # Text editor
    xfce.xfce4-taskmanager
    pavucontrol            # Audio volume control
    networkmanagerapplet
    xdg-utils
    xdg-desktop-portal
    xdg-desktop-portal-gtk
  ];
}
