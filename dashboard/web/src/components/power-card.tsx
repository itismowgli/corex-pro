import * as React from "react"
import { AlertTriangleIcon, PowerIcon, RotateCcwIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import type { Metrics, PowerMode } from "@/lib/api"

/**
 * Rebooting and shutting down the machine.
 *
 * Kept in its own card, styled as the one dangerous thing on the page, because
 * the two halves are not equally dangerous and neither is like anything else
 * here. A reboot comes back. A shutdown does not: this page runs on the box it
 * would be switching off, the tunnel goes down with it, and no button
 * anywhere can start it again. So the card says what will bring it back before
 * it offers to stop it.
 *
 * A clean shutdown is still worth having. The last time this machine went down
 * it was a thermal trip at 93.5C with nothing flushed, and the difference
 * between that and this is a working database afterwards.
 */

const WORD = "SHUTDOWN"

export function PowerCard({
  metrics,
  busy,
  onPower,
}: {
  metrics: Metrics | null
  busy: PowerMode | null
  onPower: (mode: PowerMode) => void
}) {
  const [asking, setAsking] = React.useState<PowerMode | null>(null)
  const [typed, setTyped] = React.useState("")

  const open = (mode: PowerMode) => {
    setTyped("")
    setAsking(mode)
  }
  const go = () => {
    if (!asking) return
    const mode = asking
    setAsking(null)
    onPower(mode)
  }

  // Only the interfaces that could answer a magic packet are worth naming.
  const wol = (metrics?.wol ?? []).filter((n) => n.supported)
  const armed = wol.filter((n) => n.enabled)

  return (
    <>
      <Card className="border-destructive/40">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-sm">
            <PowerIcon className="size-4" />
            Power
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <p className="text-muted-foreground text-sm">
            Both stop every container first, which is the part that protects the databases. Each one
            asks you to confirm who you are before it runs.
          </p>

          <div className="flex flex-wrap gap-2">
            <Button variant="secondary" disabled={!!busy} onClick={() => open("reboot")}>
              <RotateCcwIcon />
              {busy === "reboot" ? "Rebooting" : "Reboot"}
            </Button>
            <Button variant="destructive" disabled={!!busy} onClick={() => open("shutdown")}>
              <PowerIcon />
              {busy === "shutdown" ? "Shutting down" : "Shut down"}
            </Button>
          </div>

          <div className="text-muted-foreground border-t pt-3 text-xs">
            <p className="text-foreground font-medium">Getting it back on</p>
            {armed.length > 0 ? (
              <p className="mt-1">
                {armed.map((n) => n.interface).join(", ")} will wake on a magic packet, so a phone or
                a router on the same network can start the machine. That does not work from outside
                the house, because the tunnel is down while the box is off.
              </p>
            ) : wol.length > 0 ? (
              <p className="mt-1">
                {wol.map((n) => n.interface).join(", ")} can wake on a magic packet but it is
                switched off. Turn it on with{" "}
                <code className="text-foreground">sudo corex manage power wol on</code>.
              </p>
            ) : (
              <p className="mt-1">
                No interface here reports being able to wake on a magic packet, so the network cannot
                start this machine.
              </p>
            )}
            <p className="mt-2">
              The one way back that works from anywhere, and from a hung machine as well as a clean
              shutdown, is a smart plug with "restore on AC power loss" set in the BIOS. Cut the
              power, restore it, the box boots.
            </p>
          </div>
        </CardContent>
      </Card>

      <Dialog open={!!asking} onOpenChange={(o) => !o && setAsking(null)}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-base">
              <AlertTriangleIcon className="text-destructive size-4" />
              {asking === "shutdown" ? "Shut the machine down" : "Reboot the machine"}
            </DialogTitle>
          </DialogHeader>

          {asking === "shutdown" ? (
            <div className="flex flex-col gap-3 text-sm">
              <p>
                Every service goes down and stays down. Nobody can turn this machine on again from
                the network, including you: this page is on the machine.
              </p>
              <p className="text-muted-foreground">
                Unless a smart plug or a wake-on-LAN sender is already set up, getting it back means
                walking to it and pressing the button.
              </p>
              <div className="grid gap-1.5">
                <label htmlFor="power-word" className="font-medium">
                  Type {WORD} to confirm
                </label>
                <Input
                  id="power-word"
                  value={typed}
                  onChange={(e) => setTyped(e.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                  placeholder={WORD}
                />
              </div>
            </div>
          ) : (
            <div className="flex flex-col gap-3 text-sm">
              <p>
                Every service stops and starts again. It should be answering in a couple of minutes.
              </p>
              <p className="text-muted-foreground">
                A reboot on this box also runs the boot self-repair, which is what clears a dpkg
                database left half-configured by an interrupted upgrade.
              </p>
            </div>
          )}

          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="ghost" onClick={() => setAsking(null)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              disabled={asking === "shutdown" && typed.trim().toUpperCase() !== WORD}
              onClick={go}
            >
              {asking === "shutdown" ? "Shut down now" : "Reboot now"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
