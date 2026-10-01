import { BoxIcon, EraserIcon, HardDriveIcon, SearchIcon, TrashIcon } from "lucide-react"

import { Ansi } from "@/lib/ansi"
import { Button } from "@/components/ui/button"
import { Empty, Section } from "@/components/ui/section"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Meter } from "@/components/ui/spark"
import { StatTile } from "@/components/stat-tile"
import { StorageMap } from "@/components/storage-map"
import type { Metrics } from "@/lib/api"
import { bytes } from "@/lib/format"

/**
 * What is on the disks, and what can be had back.
 *
 * This used to print `corex manage storage` verbatim, which was wrong twice
 * over: the escape codes were rendered literally, so the page showed
 * "[0;36m[1mCoreX Storage Report[0m", and even correct they were a table of
 * numbers a reader had to parse. The same figures now come from the agent as
 * data. The raw report is still available underneath, because the command
 * remains the source of truth and this is a rendering of it.
 *
 * "What CoreX writes to" used to draw a meter per filesystem below the tiles
 * that already carry both of them, with Overview drawing a third copy. Three
 * renderings of two numbers is not three views, it is one view repeated.
 *
 * The Docker usage table stays a table: four columns compared down the page is
 * what a table is for, unlike the service list that became rows.
 */

const DOCKER_ROWS: { key: string; label: string; note: string }[] = [
  { key: "images", label: "Images", note: "layers pulled or built" },
  { key: "containers", label: "Containers", note: "writable layers" },
  { key: "local_volumes", label: "Volumes", note: "named volumes" },
  { key: "build_cache", label: "Build cache", note: "intermediate build layers" },
]

export function StorageTab({
  metrics,
  raw,
  loading,
  error,
  busy,
  locked,
  onCleanup,
}: {
  metrics: Metrics | null
  raw: string
  loading: boolean
  error: string | null
  busy: boolean
  locked: boolean
  onCleanup: (dryRun: boolean) => void
}) {
  const docker = metrics?.docker ?? null
  // What cleanup will actually take, not what Docker calls unused. The button
  // used to offer the second number and run a command that removes the first,
  // so on this hardware it advertised 3.7GB and freed nothing, every time.
  const purge = metrics?.purgeable ?? null
  const reclaimable = purge?.total_b ?? 0
  const held = purge?.held_b ?? 0
  const dueIn = purge?.next_due_h ?? null
  const sizes = metrics?.service_sizes ?? []
  const biggest = sizes.length ? sizes[0].bytes : 0
  const disks = metrics?.disks ?? []
  // The data SSD is the one that fills, and the one whose filling stops
  // services rather than merely slowing them, so it is the headline.
  const data = disks.find((d) => d.path === "/mnt/corex-data") ?? disks[disks.length - 1] ?? null
  const root = disks.find((d) => d.path === "/") ?? null
  const dockerTotal = Object.values(docker ?? {}).reduce((a, d) => a + (d?.size_b ?? 0), 0)
  const layout = metrics?.storage ?? null
  // The Time Machine partition: allocated, mounted, and on this hardware
  // holding almost nothing, which no df line makes obvious.
  const tm = layout?.disks
    .flatMap((d) => d.parts)
    .find((p) => p.label === "TIMEMACHINE" || p.mount === "/mnt/timemachine")
  const showIdle =
    layout && (layout.totals.idle_b > 0 || (tm && tm.usage && tm.usage.used_b / tm.usage.total_b < 0.02))

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-2">
        <div className="grid grid-cols-2 gap-2 sm:gap-3 lg:grid-cols-4">
          <StatTile
            icon={HardDriveIcon}
            label={data ? data.label : "Data SSD"}
            value={data ? bytes(data.used_b) : "-"}
            of={data ? bytes(data.total_b) : undefined}
            ratio={data ? data.used_b / data.total_b : undefined}
            sub={data ? `${bytes(data.free_b)} free` : "not reported"}
          />
          <StatTile
            icon={HardDriveIcon}
            label={root ? root.label : "OS disk"}
            value={root ? bytes(root.used_b) : "-"}
            of={root ? bytes(root.total_b) : undefined}
            ratio={root ? root.used_b / root.total_b : undefined}
            sub={root ? `${bytes(root.free_b)} free` : "not reported"}
          />
          <StatTile
            icon={BoxIcon}
            label="Docker storage"
            value={bytes(dockerTotal)}
            tone="ok"
            sub="images, containers, volumes and build cache"
          />
          <StatTile
            icon={TrashIcon}
            label="Purgeable now"
            value={bytes(reclaimable)}
            of={dockerTotal ? bytes(dockerTotal) : undefined}
            ratio={dockerTotal ? reclaimable / dockerTotal : undefined}
            tone={reclaimable > 0 ? "warn" : "ok"}
            sub={
              reclaimable > 0
                ? "unreferenced images and old build cache"
                : held > 0
                  ? `nothing yet, ${bytes(held)} still too new`
                  : "nothing to reclaim"
            }
          />
        </div>
        <p className="text-muted-foreground text-small">
          The OS and the Docker engine live on the internal disk; everything persistent lives on
          the SSD. Keeping them apart is what makes this box easy to migrate and restore.
        </p>
      </div>

      {layout && <StorageMap layout={layout} />}

      {showIdle && layout && (
        <Section title="Capacity that is not doing anything">
          {layout.lvm && layout.lvm.free_b > 0 && (
            <div className="flex flex-col gap-1">
              <p className="font-medium">
                {bytes(layout.lvm.free_b)} unallocated on the internal disk
              </p>
              <p className="text-muted-foreground text-small">
                Free space in the volume group that no filesystem covers, so nothing can write to
                it and no `df` mentions it. It is the fastest storage in the machine. Give some of
                it to the databases with{" "}
                <code className="text-foreground">corex manage disk fast-tier</code>, or leave it:
                LVM will grow a volume on demand but will not shrink one without a fight, so
                unspent headroom is a decision rather than waste.
              </p>
            </div>
          )}

          {tm && tm.usage && (
            <div className="flex flex-col gap-1">
              <p className="font-medium">
                Time Machine holds {bytes(tm.usage.used_b)} of its {bytes(tm.size_b)}
              </p>
              <p className="text-muted-foreground text-small">
                {tm.usage.used_b / tm.usage.total_b < 0.02 ? (
                  <>
                    Almost nothing. Backups from a Mac land in the shared pool on the data
                    partition now, so this one is a leftover from an older layout.{" "}
                  </>
                ) : (
                  <>Backups from a Mac land here. </>
                )}
                Turning Time Machine off does <span className="text-foreground">not</span> hand
                this space back on its own, and the partitions cannot simply be merged: this one
                sits <span className="text-foreground">before</span> the data partition on the
                disk, so freeing it leaves a gap in the wrong place, and a partition cannot grow
                backwards into space that precedes it. Reclaiming it means moving the data
                partition's start, with every service stopped. Using it where it is, as somewhere
                separate to write backups, costs nothing and needs no downtime.
              </p>
            </div>
          )}
        </Section>
      )}

      <Section
        title="Docker usage"
        action={
          <>
            <Button size="xs" variant="secondary" disabled={busy || locked} onClick={() => onCleanup(true)}>
              <SearchIcon />
              Preview cleanup
            </Button>
            <Button
              size="xs"
              variant="outline"
              disabled={busy || locked || reclaimable === 0}
              title={
                reclaimable === 0
                  ? "Nothing is removable right now"
                  : "Remove unreferenced images and build cache"
              }
              onClick={() => {
                if (
                  window.confirm(
                    "Remove unreferenced images and build cache? No service data is deleted."
                  )
                )
                  onCleanup(false)
              }}
            >
              <EraserIcon />
              {reclaimable === 0 ? "Nothing to reclaim" : `Reclaim ${bytes(reclaimable)}`}
            </Button>
          </>
        }
      >
        {!docker ? (
          <Empty>Docker did not report its usage.</Empty>
        ) : (
          <div className="w-full overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>What</TableHead>
                  <TableHead className="text-right">Count</TableHead>
                  <TableHead className="text-right">Size</TableHead>
                  <TableHead className="text-right">Purgeable</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {DOCKER_ROWS.map(({ key, label, note }) => {
                  const row = docker[key]
                  if (!row) return null
                  return (
                    <TableRow key={key}>
                      <TableCell>
                        <div>{label}</div>
                        <div className="text-muted-foreground text-small">{note}</div>
                      </TableCell>
                      <TableCell className="num text-right font-mono text-small">
                        {row.active}/{row.count}
                      </TableCell>
                      <TableCell className="num text-right font-mono text-small">
                        {bytes(row.size_b)}
                      </TableCell>
                      <TableCell
                        className={`num text-right font-mono text-small ${
                          row.reclaimable_b > 0 ? "text-warn" : "text-muted-foreground"
                        }`}
                      >
                        {row.reclaimable_b > 0 ? bytes(row.reclaimable_b) : "-"}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          </div>
        )}
        <p className="text-muted-foreground text-small">
          Cleanup removes images no container references, stopped containers included, and all
          reclaimable build cache. It never touches service data, and it never runs a volume
          prune, because that would destroy every unnamed volume including ones in use.
        </p>
        {held > 0 && (
          <p className="text-muted-foreground text-small">
            A further <span className="text-foreground font-mono">{bytes(held)}</span> of build
            cache is unused but too new to remove
            {dueIn != null && (
              <>
                . The oldest of it becomes eligible in about{" "}
                {dueIn < 1 ? "an hour" : `${Math.round(dueIn)} hours`}
              </>
            )}
            . Docker counts that as reclaimable; this panel does not, because a button that offers
            space it will not free is how this one came to do nothing at all.
          </p>
        )}
      </Section>

      <Section title="Space per service">
        {loading && !metrics ? (
          <Empty>Reading.</Empty>
        ) : sizes.length === 0 ? (
          <Empty>
            Still measuring. Walking a photo library takes a while, so this is computed in the
            background and refreshed every fifteen minutes.
          </Empty>
        ) : (
          <div className="flex flex-col gap-2">
            {sizes.map((s) => (
              <Meter
                key={s.name}
                value={s.bytes}
                max={biggest || 1}
                tone="neutral"
                caption={s.name}
                right={bytes(s.bytes)}
              />
            ))}
          </div>
        )}
      </Section>

      {(raw || error) && (
        <details className="text-muted-foreground text-small">
          <summary className="cursor-pointer select-none">The report this is rendered from</summary>
          <Ansi
            text={raw || error || ""}
            className="term bg-muted/40 mt-2 max-h-[40vh] overflow-auto rounded-lg px-3 py-2"
          />
        </details>
      )}
    </div>
  )
}
