{ diskDevice, ... }:

{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = diskDevice;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              name = "ESP";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["fmask=0077" "dmask=0077"];
              };
            };
            cryptswap = {
              name = "cryptswap";
              size = "8G";
              type = "8200"; # Linux swap
              content = {
                type = "luks";
                name = "cryptswap";
                settings.keyFile = "/dev/urandom";
                content = {
                  type = "swap";
                  discardPolicy = "both";
                  priority = 100;
                };
              };
            };
            cryptroot = {
              name = "cryptroot";
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";
                settings = {
                  allowDiscards = true;
                  bypassWorkqueues = true;
                };
                # Unlocks in initrd so ZFS pool is available at boot
                initrdUnlock = true;
                content = {
                  type = "zfs";
                  pool = "zroot";
                };
              };
            };
          };
        };
      };

      # ── Future mirror ───────────────────────────────────────────
      # When you add a second NVMe:
      #   1. Uncomment this disk block
      #   2. Set its device path
      #   3. Set zpool.zroot.mode = "mirror"
      #   4. Run: zpool attach zroot /dev/disk/by-id/<nvme0-cryptroot> /dev/disk/by-id/<nvme1-cryptroot>
      #
      # nvme1 = {
      #   type = "disk";
      #   device = "/dev/disk/by-id/nvme-<second-disk-serial>";
      #   content = {
      #     type = "gpt";
      #     partitions = {
      #       ESP = {
      #         name = "ESP2";
      #         size = "512M";
      #         type = "EF00";
      #         content = {
      #           type = "filesystem";
      #           format = "vfat";
      #           mountpoint = "/boot2"; # not mounted by default
      #         };
      #       };
      #       cryptroot = {
      #         name = "cryptroot2";
      #         size = "100%";
      #         content = {
      #           type = "luks";
      #           name = "cryptmirror";
      #           settings.allowDiscards = true;
      #           initrdUnlock = true;
      #           content = {
      #             type = "zfs";
      #             pool = "zroot";
      #           };
      #         };
      #       };
      #     };
      #   };
      # };
    };

    zpool = {
      zroot = {
        type = "zpool";
        mode = ""; # single disk initially; change to "mirror" for RAID 1

        options = {
          ashift = "12";
          autotrim = "on";
        };

        rootFsOptions = {
          compression = "lz4";
          atime = "off";
          "com.sun:auto-snapshot" = "false";
        };

        datasets = {
          # ── Top-level container for auto-snapshotted datasets ──
          "safe" = {
            type = "zfs_fs";
            options."com.sun:auto-snapshot" = "true";
          };

          # ── Nix store — persistent, not snapshotted ────────────
          "safe/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.mountpoint = "/nix";
          };

          # ── Impermanence backing store ─────────────────────────
          "safe/persist" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
          };

          # ── Logs — persistent ────────────────────────────────
          "safe/log" = {
            type = "zfs_fs";
            mountpoint = "/var/log";
          };

          # ── Caches — persistent ──────────────────────────────
          "safe/cache" = {
            type = "zfs_fs";
            mountpoint = "/var/cache";
          };
        };
      };
    };
  };
}
