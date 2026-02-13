# 💣 CoreX Pro — Nuke & Rollback Guide

> **Script:** `nuke-corex.sh`
> **Companion to:** `install-corex-master.sh`

The nuke script cleanly reverses everything the installer did. It's your safety net — whether an installation went sideways, you want a fresh start, or you're decommissioning the server.

---

## When to Use This

| Scenario                        | What to Nuke                 | Command                                                |
| ------------------------------- | ---------------------------- | ------------------------------------------------------ |
| Installation failed mid-way     | Everything, then re-install  | `sudo bash nuke-corex.sh --all`                        |
| Single service is broken        | Just that service manually   | Don't use nuke — see [Manual Fix](#manual-service-fix) |
| Want to re-install from scratch | Everything except SSD data   | Run interactive, skip Phase 9                          |
| Moving to a new machine         | Just clean up the old server | `sudo bash nuke-corex.sh --all`                        |
| Decommissioning the server      | Everything including SSD     | Run interactive, include Phase 9                       |
| Testing what would happen       | Nothing — just preview       | `sudo bash nuke-corex.sh --dry-run`                    |

---

## Usage

```bash
# Interactive — choose what to nuke (recommended)
sudo bash nuke-corex.sh

# Full nuke — runs all phases (still asks for confirmation)
sudo bash nuke-corex.sh --all

# Dry run — shows what would happen without doing anything
sudo bash nuke-corex.sh --dry-run

# Help
sudo bash nuke-corex.sh --help
```

---

## What Each Phase Does

The script runs 10 phases in order. In interactive mode, each phase asks for confirmation — you can skip any phase with `N`.

### Phase 1: Docker Containers & Networks

**Undoes:** All running services

- Stops each docker-compose stack gracefully (in order)
- Force-removes any remaining containers
- Removes `proxy-net`, `monitoring-net`, `ai-net` networks
- Removes all Docker volumes
- Prunes unused images to free disk space

**Your data on the SSD is NOT touched.** Only the running containers and Docker's internal storage are affected.

**Skip if:** You have non-CoreX containers running on the same machine.

---

### Phase 2: Backup System

**Undoes:** Phase 6 of the installer (Restic setup)

- Removes the `corex-backup` cron job (daily 3AM backup)
- Deletes `/usr/local/bin/corex-backup.sh`
- Deletes `/usr/local/bin/corex-restore.sh`

**Does NOT delete:** The actual Restic backup repository on the SSD. Your backup snapshots are preserved.

**Skip if:** You want to keep the backup scripts for manual use.

---

### Phase 3: Firewall (UFW)

**Undoes:** All UFW rules from the installer

- Disables UFW
- Resets all rules to factory defaults
- Re-enables with only port 22 (SSH) open

**After this:** Only SSH on port 22 is accessible. All service ports are blocked until you re-run the installer or add rules manually.

**Skip if:** You have custom UFW rules you want to keep.

---

### Phase 4: Security Hardening

**Undoes:** Phase 2 of the installer (security hardening)

- **SSH:** Restores from the `.bak` file the installer created, or resets to defaults (port 22, root login disabled, 6 max auth attempts)
- **Fail2ban:** Removes `/etc/fail2ban/jail.local` (CoreX jail config)
- **Kernel:** Removes `/etc/sysctl.d/99-corex.conf` and reloads sysctl
- Cleans up SSH config backup files

**⚠️ After this, SSH moves back to port 22.** If you're connected via SSH on port 2222, you'll need to reconnect on port 22.

**Skip if:** You want to keep the SSH hardening.

---

### Phase 5: DNS Resolution

**Undoes:** systemd-resolved disabling and resolv.conf lock

- Unlocks `/etc/resolv.conf` (removes `chattr +i`)
- Deletes the static resolv.conf
- Re-enables `systemd-resolved`
- Restores the Ubuntu default symlink

**After this:** The server uses standard Ubuntu DNS resolution. AdGuard Home is no longer the DNS server (since containers are already removed in Phase 1).

**Skip if:** You have custom DNS configuration you want to keep.

---

### Phase 6: SSD Mounts & Fstab

**Undoes:** Phase 1 of the installer (drive setup)

- Unmounts `/mnt/timemachine` and `/mnt/corex-data`
- Removes both entries from `/etc/fstab`
- Removes the empty mount point directories

**Your data stays on the SSD.** The partitions and files are not touched — they're just no longer mounted. You can re-mount them later or plug the SSD into another machine.

**Skip if:** You want to keep the SSD mounted (e.g., to copy data off it first).

---

### Phase 7: Docker Engine

**Undoes:** Phase 3 of the installer (Docker installation)

- Stops Docker, containerd, and Docker socket
- Purges all Docker packages (docker-ce, docker-ce-cli, containerd, compose plugin, buildx)
- Removes `/var/lib/docker` and `/var/lib/containerd`
- Removes Docker's apt repository and GPG key

**This is optional.** If you use Docker for other projects, skip this phase.

**Skip if:** You need Docker for anything else on this machine.

---

### Phase 8: Credentials & Documentation

**Undoes:** Credential and doc files created by the installer

- **Makes a backup copy first** to `/root/corex-creds-backup-<timestamp>/`
- Removes `/root/corex-credentials.txt`
- Removes `/root/CoreX_Dashboard_Credentials.md`

**Your passwords are backed up before deletion.** The backup directory is printed in the summary. Delete it manually after you've saved your passwords elsewhere.

---

### Phase 9: Wipe SSD Data ⚠️ DESTRUCTIVE

**Permanently deletes everything on the SSD:**

- All service data (databases, uploads, photos, mail, passwords)
- All docker-compose configs
- All Restic backup snapshots
- All Time Machine backups
- Wipes the partition table

**Requires double confirmation:** You must type `WIPE MY DATA` exactly.

**This cannot be undone.** Only use this when you're certain you don't need any data from the SSD.

**Skip if:** You want to keep your data (most common choice).

---

### Phase 10: Installed Packages

**Undoes:** Package installations from Phase 2 of the installer

Removes only packages specifically installed by CoreX:

- `restic` (backup tool)
- `avahi-daemon` and `avahi-utils` (Bonjour/mDNS)
- `fail2ban` (brute force protection)

**Does NOT remove:** Common utilities like curl, wget, nano, htop, jq, net-tools (these are useful regardless of CoreX).

**Skip if:** Other services depend on these packages.

---

## Manual Service Fix

If only one service is broken, don't nuke everything. Fix it directly:

```bash
# Check what's wrong
docker logs SERVICE_NAME --tail 50

# Restart the service
cd /mnt/corex-data/docker-configs/SERVICE_NAME
docker compose down
docker compose up -d

# If the compose file is corrupted, re-run just the installer
# (it's idempotent — it skips what's already done)
sudo bash install-corex-master.sh
```

---

## Recovery Scenarios

### Scenario 1: Installation failed at Phase 5 (services)

Some containers started, some didn't. DNS might be broken.

```bash
# Nuke containers and retry
sudo bash nuke-corex.sh
# → Phase 1 (containers): Yes
# → Phase 2-10: No (skip all)

# Re-run installer
sudo bash install-corex-master.sh
# It will detect existing partitions, load credentials, and redeploy
```

### Scenario 2: Complete fresh start (keep SSD data)

Want to redo everything but preserve photos, mail, and backups.

```bash
sudo bash nuke-corex.sh
# → Phase 1-8: Yes (everything)
# → Phase 9 (wipe SSD): NO ← important!
# → Phase 10: Your choice

# Re-run installer
sudo bash install-corex-master.sh
# Choose "skip format" when asked about the drive
# It will re-mount existing partitions and redeploy with existing data
```

### Scenario 3: Total wipe — sell the machine

```bash
sudo bash nuke-corex.sh --all
# Type NUKE when asked
# → Phase 9: Yes, type WIPE MY DATA
# Machine is clean
```

### Scenario 4: Migrate to new hardware

```bash
# On OLD server: backup first
sudo corex-backup.sh

# On NEW server: install Ubuntu 24.04 LTS, then:
sudo bash install-corex-master.sh

# Copy backup repo from old SSD to new SSD:
rsync -avP old-server:/mnt/corex-data/backups/restic-repo/ /mnt/corex-data/backups/restic-repo/

# Restore
sudo corex-restore.sh latest

# On OLD server: nuke
sudo bash nuke-corex.sh --all
```

---

## Safety Features

| Feature                          | How It Works                                   |
| -------------------------------- | ---------------------------------------------- |
| Interactive mode                 | Every phase asks for confirmation              |
| `--dry-run`                      | Shows commands without executing               |
| `--all` requires typing "NUKE"   | Prevents accidental full wipe                  |
| SSD wipe requires "WIPE MY DATA" | Double confirmation for destructive action     |
| Credentials backed up first      | Copy made before deletion                      |
| SSH restored last                | You maintain remote access throughout          |
| Full log file                    | Every action logged to `/tmp/corex-nuke-*.log` |

---

## Files Affected

This is a complete list of everything the nuke script can remove or modify:

| File/Path                                           | Phase | Action                           |
| --------------------------------------------------- | ----- | -------------------------------- |
| All Docker containers                               | 1     | Removed                          |
| Docker networks (proxy-net, monitoring-net, ai-net) | 1     | Removed                          |
| Docker volumes                                      | 1     | Removed                          |
| Docker images (unused)                              | 1     | Pruned                           |
| `/usr/local/bin/corex-backup.sh`                    | 2     | Deleted                          |
| `/usr/local/bin/corex-restore.sh`                   | 2     | Deleted                          |
| Crontab entry (corex-backup)                        | 2     | Removed                          |
| All UFW rules                                       | 3     | Reset to defaults                |
| `/etc/ssh/sshd_config`                              | 4     | Restored from backup or reset    |
| `/etc/ssh/sshd_config.bak.*`                        | 4     | Deleted                          |
| `/etc/fail2ban/jail.local`                          | 4     | Deleted                          |
| `/etc/sysctl.d/99-corex.conf`                       | 4     | Deleted                          |
| `/etc/resolv.conf`                                  | 5     | Restored to systemd-resolved     |
| `/etc/fstab` (CoreX entries)                        | 6     | Removed                          |
| `/mnt/timemachine` (mount point)                    | 6     | Unmounted + removed              |
| `/mnt/corex-data` (mount point)                     | 6     | Unmounted + removed              |
| Docker Engine packages                              | 7     | Purged (optional)                |
| `/var/lib/docker`, `/var/lib/containerd`            | 7     | Deleted (optional)               |
| `/root/corex-credentials.txt`                       | 8     | Backed up + deleted              |
| `/root/CoreX_Dashboard_Credentials.md`              | 8     | Backed up + deleted              |
| SSD partitions + data                               | 9     | Wiped (optional, double confirm) |
| restic, avahi, fail2ban packages                    | 10    | Purged (optional)                |
