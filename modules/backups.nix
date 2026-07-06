{ lib, pkgs, ... }:

let
  # Creates a restic backup script for one target (R2, B2, etc.)
  # The env file at $path must export:
  #   RESTIC_REPOSITORY, RESTIC_PASSWORD, and any rclone config vars
  backupScript = name: envFile: pkgs.writeShellScript "restic-backup-${name}" ''
    set -euo pipefail
    [ -f "${envFile}" ] || { echo "❌ Missing ${envFile} — create it first (see module docs)"; exit 1; }
    source "${envFile}"

    restic backup \
      /home/liam/Documents \
      /home/liam/Projects \
      /persist \
      --exclude-file=/etc/restic/excludes.txt

    # Lightweight integrity check (1% of data, ≈daily)
    restic check --read-data-subset=1%
  '';

  # Full data verification (weekly)
  verifyScript = name: envFile: pkgs.writeShellScript "restic-verify-${name}" ''
    set -euo pipefail
    [ -f "${envFile}" ] || { echo "❌ Missing ${envFile}"; exit 1; }
    source "${envFile}"
    restic check --read-data
  '';

  # Restore drill — verifies we can actually restore files
  restoreDrillScript = name: envFile: pkgs.writeShellScript "restic-drill-${name}" ''
    set -euo pipefail
    [ -f "${envFile}" ] || { echo "❌ Missing ${envFile}"; exit 1; }
    source "${envFile}"

    TARGET=$(mktemp -d /tmp/restic-drill.XXXXXX)
    trap 'rm -rf "$TARGET"' EXIT

    restic snapshots latest >/dev/null
    restic restore latest --target "$TARGET" --include /persist/etc >/dev/null

    if [ ! -f "$TARGET/persist/etc/machine-id" ]; then
      echo "FAIL: restore drill — expected /persist/etc/machine-id missing"
      exit 1
    fi
    echo "PASS: restore drill — successfully restored /persist/etc"
  '';

  # The active backup env file path
  backupEnv = "/etc/restic/r2.env";
in

{
  # ── Dependencies ──────────────────────────────────
  environment.systemPackages = with pkgs; [ restic rclone ];

  # ── Exclude patterns ──────────────────────────────
  environment.etc."restic/excludes.txt".text = ''
    .cache
    .direnv
    node_modules
    target
    _build
    deps
    *.tmp
    *.swp
  '';

  # ════════════════════════════════════════════════════════════════════
  #  SETUP — one-time, after first boot:
  #
  #  sudo mkdir -p /etc/restic
  #  sudo vi /etc/restic/r2.env
  #
  #  ── R2 (Cloudflare) example ───────────────────────────────────
  #    export RESTIC_REPOSITORY=rclone:r2:my-bucket/p51
  #    export RESTIC_PASSWORD=your-secure-password-here
  #    export RCLONE_CONFIG_R2_TYPE=s3
  #    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  #    export RCLONE_CONFIG_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
  #    export RCLONE_CONFIG_R2_ACCESS_KEY_ID=...
  #    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
  #
  #  ── Backblaze B2 (alternate) ──────────────────────────────────
  #    export RESTIC_REPOSITORY=rclone:b2:my-bucket/p51
  #    export RESTIC_PASSWORD=your-secure-password-here
  #    export RCLONE_CONFIG_B2_TYPE=b2
  #    export RCLONE_CONFIG_B2_ACCOUNT=...
  #    export RCLONE_CONFIG_B2_KEY=...
  #
  #  ── Init & test ──────────────────────────────────────────────
  #    sudo restic -r "$(grep ^RESTIC_REPOSITORY /etc/restic/r2.env | cut -d= -f2-)" init
  #    sudo systemctl start restic-backup-r2
  #    sudo journalctl -u restic-backup-r2 -f
  # ════════════════════════════════════════════════════════════════════

  # ── Primary backup ──
  systemd.services.restic-backup-r2 = {
    description = "Nightly Restic backup to Cloudflare R2";
    serviceConfig.Type = "oneshot";
    script = "${backupScript "r2" backupEnv}";
    path = [ pkgs.restic pkgs.rclone ];
  };

  systemd.timers.restic-backup-r2 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
    };
  };

  # ── Secondary backup (B2) — uncomment to enable dual-cloud ──
  # systemd.services.restic-backup-b2 = {
  #   description = "Nightly Restic backup to Backblaze B2";
  #   serviceConfig.Type = "oneshot";
  #   script = "${backupScript "b2" "/etc/restic/b2.env"}";
  #   path = [ pkgs.restic pkgs.rclone ];
  # };
  #
  # systemd.timers.restic-backup-b2 = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  # };

  # ── Weekly deep verification (Sun 4 AM) ──
  systemd.services.restic-verify-deep = {
    description = "Weekly full Restic data verification";
    serviceConfig.Type = "oneshot";
    script = "${verifyScript "r2" backupEnv}";
    path = [ pkgs.restic pkgs.rclone ];
  };

  systemd.timers.restic-verify-deep = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = true;
    };
  };

  # ── Monthly restore drill (1st Sun 5 AM) ──
  systemd.services.restic-restore-drill = {
    description = "Monthly Restic restore drill";
    serviceConfig.Type = "oneshot";
    script = "${restoreDrillScript "r2" backupEnv}";
    path = [ pkgs.restic pkgs.rclone pkgs.coreutils ];
  };

  systemd.timers.restic-restore-drill = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 05:00";
      Persistent = true;
    };
  };

  # ── Impermanence: /etc/restic survives reboots ──
  environment.persistence."/persist".directories = [ "/etc/restic" ];
}
