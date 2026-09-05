import { HardDriveIcon, UsbIcon, ZapIcon } from "lucide-react"

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { PhysicalDisk, StorageLayout } from "@/lib/api"
import { bytes } from "@/lib/format"

/**
 * Every disk in the box, drawn to one scale.
 *
 * The Disks card above answers "is anything filling up", which is the
 * operational question. This answers the different one: what hardware is
 * fitted, how it is divided, and which parts of it are doing nothing. Those
 * are not the same, and the gap is where capacity hides. On this box a 400GB
 * partition sat idle because Time Machine had moved elsewhere, and 240GB of
 * the internal NVMe had never been handed out at all. Neither appears in any
 * `df` output, so neither was ever noticed.
 *
 * One scale across every disk, so a 512GB disk draws half the width of a 1TB
 * one. Two bars normalised to their own widths would make the smaller disk
 * look like the bigger problem.
 */

type Seg = { label: string; sub: string; frac: number; tone: SegTone; note?: string }
type SegTone = "used" | "free" | "idle" | "system"

const TONE: Record<SegTone, string> = {
  used: "bg-[var(--seg-used)]",
  free: "bg-[var(--seg-free)]",
  idle: "bg-[var(--seg-idle)]",
  system: "bg-[var(--seg-system)]",
}

function diskIcon(t: string | null) {
  if (t === "nvme") return ZapIcon
  if (t === "usb") return UsbIcon
  return HardDriveIcon
}

/** A partition, split into what it holds and what is spare inside it. */
function partSegments(disk: PhysicalDisk): Seg[] {
  const segs: Seg[] = []
  for (const p of disk.parts) {
    const isSystem = p.mount === "/boot" || p.mount === "/boot/efi"
    // The LVM member carries the logical volumes, which are listed separately.
    // Calling it unused would be wrong, and calling it used would double count.
    const isPV = p.fstype === "LVM2_member"
    const name = p.label || p.mount || p.name

    if (isPV) {
      segs.push({
        label: name, sub: bytes(p.size_b), frac: p.size_b, tone: "system",
        note: "holds the logical volumes below",
      })
      continue
    }
    if (!p.usage) {
      segs.push({ label: name, sub: bytes(p.size_b), frac: p.size_b, tone: "idle",
                  note: "not mounted" })
      continue
    }
    const used = p.usage.used_b
    const spare = Math.max(0, p.size_b - used)
    // A partition holding almost nothing is the thing worth seeing, so it is
    // drawn as idle rather than as free space inside something in use.
    const barelyUsed = p.usage.total_b > 0 && used / p.usage.total_b < 0.02
    segs.push({
      label: name, sub: `${bytes(used)} of ${bytes(p.size_b)}`,
      frac: used, tone: isSystem ? "system" : "used",
      note: p.mount || undefined,
    })
    segs.push({
      label: `${name} spare`, sub: bytes(spare), frac: spare,
      tone: barelyUsed ? "idle" : "free",
      note: barelyUsed ? "allocated, but holding almost nothing" : undefined,
    })
  }
  if (disk.unallocated_b > 0) {
    segs.push({ label: "unallocated", sub: bytes(disk.unallocated_b),
                frac: disk.unallocated_b, tone: "idle",
                note: "no partition covers it" })
  }
  return segs.filter((s) => s.frac > 0)
}

function DiskRow({ disk, scale }: { disk: PhysicalDisk; scale: number }) {
  const Icon = diskIcon(disk.transport)
  const segs = partSegments(disk)
  const width = scale > 0 ? (disk.size_b / scale) * 100 : 100
  return (
    <div className="grid gap-1.5">
      <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-xs">
        <Icon className="text-muted-foreground size-3.5 shrink-0 self-center" />
        <span className="font-medium">{disk.model || disk.name}</span>
        <span className="text-muted-foreground font-mono">
          {disk.name} · {bytes(disk.size_b)}
          {disk.transport ? ` · ${disk.transport}` : ""}
        </span>
      </div>
      {/* min-width keeps a small disk's bar readable rather than a sliver. */}
      <div className="flex h-9 gap-px overflow-hidden rounded-md border"
           style={{ width: `${Math.max(width, 22)}%`, minWidth: "200px" }}>
        {segs.map((s, i) => (
          <div key={`${s.label}-${i}`} className={TONE[s.tone]}
               style={{ flexGrow: s.frac, flexBasis: 0, minWidth: 0 }}
               title={`${s.label}: ${s.sub}${s.note ? ` (${s.note})` : ""}`} />
        ))}
      </div>
      <div className="grid gap-0.5">
        {segs
          .filter((s) => s.tone !== "free" || s.frac / disk.size_b > 0.08)
          .map((s, i) => (
            <div key={`${s.label}-l-${i}`}
                 className="text-muted-foreground flex flex-wrap items-baseline gap-x-2 text-[11px]">
              <span className={`size-2 shrink-0 self-center rounded-[2px] ${TONE[s.tone]}`} />
              <span className="text-foreground">{s.label}</span>
              <span className="font-mono">{s.sub}</span>
              {s.note && <span>{s.note}</span>}
            </div>
          ))}
      </div>
    </div>
  )
}

export function StorageMap({ layout }: { layout: StorageLayout }) {
  const scale = Math.max(1, ...layout.disks.map((d) => d.size_b))
  const lvm = layout.lvm
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
          <HardDriveIcon className="size-4" />
          Every disk in the box
          <span className="text-muted-foreground ml-auto font-mono text-xs">
            {bytes(layout.totals.raw_b)} fitted
          </span>
        </CardTitle>
      </CardHeader>
      <CardContent className="grid gap-5">
        {layout.disks.map((d) => (
          <DiskRow key={d.name} disk={d} scale={scale} />
        ))}

        {layout.volumes && layout.volumes.length > 0 && (
          <div className="grid gap-1.5 border-t pt-4">
            <p className="text-muted-foreground text-[11px]">
              Logical volumes, carved out of the internal disk
            </p>
            {layout.volumes.map((v) => (
              <div key={v.name}
                   className="flex flex-wrap items-baseline gap-x-2 text-[11px]">
                <span className="text-foreground">{v.mount || v.name}</span>
                <span className="text-muted-foreground font-mono">
                  {v.usage ? `${bytes(v.usage.used_b)} of ${bytes(v.size_b)}` : bytes(v.size_b)}
                </span>
              </div>
            ))}
            {lvm && lvm.free_b > 0 && (
              <div className="flex flex-wrap items-baseline gap-x-2 text-[11px]">
                <span className="size-2 shrink-0 self-center rounded-[2px] bg-[var(--seg-idle)]" />
                <span className="text-foreground">unallocated in {lvm.vg}</span>
                <span className="text-muted-foreground font-mono">{bytes(lvm.free_b)}</span>
                <span className="text-muted-foreground">
                  free space on the fastest disk, waiting to be given a job
                </span>
              </div>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  )
}
