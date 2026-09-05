# Performance, cold services and storage

## Dashboard

Live CPU and memory use one shared five-second server sampler, independent of viewer count.
The browser connects on Overview and closes the stream while hidden. Polling
also pauses while hidden and refreshes on return. Storage scans, logs, SMART,
SQLite and maintenance reads are excluded from the five-second metrics path.
Container CPU and memory rankings refresh at most every 30 seconds because the
Docker stats command itself consumes a sampling interval. Previously rendered
service cards remain visible during refreshes.

The changes reduce collection work; CPU, RAM and temperature reductions still
need to be measured on the server under comparable load. Browser background
throttling is not a substitute for the host's thermal guardian.

## Service policy

| Services | Policy |
| --- | --- |
| DNS, reverse proxy, authentication, dashboard, tunnel | Always available |
| Keeper, Cal.com, Nextcloud, mail, n8n, backups | Stay running for sync, schedules and incoming work |
| Immich | Stay running for uploads and indexing; manage job concurrency in Immich |
| Ollama | One loaded model, one parallel inference, unload after two minutes idle |
| Browserless | At most two concurrent browser sessions |
| Portainer | Optional automatic container sleep after 15 minutes without HTTP activity |

Ollama's API clients can override `keep_alive` per request; check those clients
if models remain resident. A cold model reload takes longer for the first request.
The existing CPU-clock ceiling and thermal shedding remain in force. Use
`corex manage power`, `corex manage watchdog`, and `corex manage status` to inspect
their configured state before changing thresholds. Do not raise thermal shutdown
limits to hide heat.

### Portainer wake on access

After finishing Portainer's admin setup, on a server running Traefik 3.6+:

```sh
corex manage cold enable portainer
corex manage cold status
```

This installs Sablier, enables its pinned Traefik plugin and recreates Portainer
with opt-in labels. Open `https://portainer.YOUR_DOMAIN` once to establish its
idle session. Later requests show a waiting page while the container starts.
Long-lived proxied connections renew the session. Access to port 9443 directly
cannot wake a stopped container. Use the HTTPS hostname for this mode.

Existing IP restrictions and shared authentication run before the wake
middleware. Uptime Kuma's User-Agent receives a synthetic success without waking
Portainer, so that check verifies the route, not the sleeping application. Do not
use this option if you rely on Portainer's own scheduled background tasks.

```sh
corex manage cold disable portainer
```

Disabling restores an always-running Portainer. The dashboard Stop action also
removes its wake configuration so a web request cannot undo a deliberate stop.
Sablier has no published port; its Docker control socket is privileged, like
Portainer's. CoreX permits only opted-in containers and does not automatically
apply sleep to databases, calendar services, workflows or backups.

Source: [Sablier Traefik integration](https://github.com/sablierapp/sablier-traefik-plugin),
[Ollama memory and concurrency settings](https://docs.ollama.com/faq).

## One shared data partition

New installs create a GPT with one ext4 partition labelled `COREX_DATA`. The
filesystem starts at 1 MiB and uses 98% of the disk by default. The remaining 2%
is unallocated headroom, not another filesystem; set `COREX_SSD_RESERVE_PERCENT`
from 0 to 20 before installation to change it. This is separate from ext4's 1%
reserved blocks. The Time Machine service already stores backups in
`/mnt/corex-data/timemachine-data` and needs no dedicated partition.

The reuse option mounts labelled single-partition or legacy two-partition disks.
It does not silently relabel or format an unknown filesystem. Cancelling the
format confirmation leaves Docker and the disk alone. The OS disk and disks
with unrelated mounted filesystems are refused.

### Existing two-partition disks need a migration

**Do not rerun the installer to reclaim space on a live server.** If TIMEMACHINE
precedes COREX_DATA, deleting it leaves space before the data filesystem; growing
that filesystem does not move its start. The supported migration plan is:

1. Record `lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS`, `findmnt`, `df -h`,
   and any LVM/bind mounts. Check what still uses `/mnt/timemachine`.
   `corex manage disk shared-plan` prints a read-only assessment of the labels,
   partition order and whether the configured backup sits on the same disk.
2. Make a verified backup to a different physical disk or remote repository.
   A restic repository inside `/mnt/corex-data/backups` is on the disk being
   erased and is not sufficient. Include Time Machine's old contents if needed,
   service data, compose directories, `/etc/corex`, credentials and database dumps.
3. Test restoration of representative files and databases. Schedule downtime,
   stop writers and Docker/socket activation, and make the final backup.
4. Only after the exact device and backup are approved, recreate that external
   disk as the shared data layout and restore ownership, permissions, ACLs and
   extended attributes. Keep the operating-system disk unchanged.
5. Replace only CoreX fstab entries, remove obsolete Time Machine mount
   dependencies, and verify mount guards before starting Docker. Verify services
   and calendar data before declaring the migration complete.

Keep the small database tier on the **internal NVMe**, separate from the external
pool. `corex manage disk fast-status` reports it; `fast-tier` uses free LVM space
and `fast-commit` removes retained old copies only after verification. Keeper's
database is included in that tier's supported directories. The actual allocation
must be chosen from the server's available LVM space and database sizes.
