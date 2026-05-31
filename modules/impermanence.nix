{ lib, pkgs, impermanence, ... }:

let
  inherit (lib) mkDefault;

  # Paths that must survive reboots — bind-mounted from /persist
  persistentDirs = [
    "/etc/ssh"
    "/etc/NetworkManager/system-connections"
    "/etc/machine-id"
    "/var/lib/bluetooth"
    "/var/lib/nixos"
  ];

  # Files that must survive reboots
  persistentFiles = [
    "/etc/resolv.conf"
  ];
in {
  imports = [ impermanence.nixosModules.impermanence ];

  # ── Root is tmpfs — everything ephemeral ──────────
  boot.initrd.systemd.enable = mkDefault true;
  fileSystems."/".device = "none";
  fileSystems."/".fsType = "tmpfs";
  fileSystems."/".options = ["defaults" "size=2G" "mode=755"];

  # ── /persist is the ZFS persistent store ─────────
  # Dataset: zroot/safe/persist (mountpoint=legacy in disko)
  fileSystems."/persist" = {
    device = "zroot/safe/persist";
    fsType = "zfs";
    neededForBoot = true;
  };

  # ── Bind-mount persistent directories from /persist ──
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = persistentDirs;
    files = persistentFiles;

    users.liam = {
      directories = [
        ".ssh"
        ".local/share/keyrings"
        ".local/share/direnv"
        ".gnupg"
        "Downloads"
        "Documents"
        "Projects"
        ".config"
      ];
      files = [];
    };
  };

  # ── systemd-tmpfiles — ensure /persist layout on first boot ──
  systemd.tmpfiles.rules = let
    mkDir = mode: path: "d ${path} ${mode} root root -";
  in
    (map (mkDir "0755") [
      "/persist"
      "/persist/etc/ssh"
      "/persist/etc/NetworkManager/system-connections"
      "/persist/var/lib/bluetooth"
      "/persist/var/lib/nixos"
    ])
    ++ (map (mkDir "0700") [
      "/persist/home/liam/.ssh"
      "/persist/home/liam/.gnupg"
    ]);
}
