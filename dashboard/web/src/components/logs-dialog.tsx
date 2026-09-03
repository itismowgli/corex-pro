import * as React from "react"

import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { api } from "@/lib/api"

/**
 * Live container logs over Server-Sent Events. Closing the dialog closes the
 * EventSource, which cancels `docker logs -f` on the server: the subprocess is
 * tied to the request context, so an abandoned stream does not leave one
 * running.
 */
export function LogsDialog({
  container,
  label,
  onClose,
}: {
  container: string | null
  label: string
  onClose: () => void
}) {
  const [lines, setLines] = React.useState<string[]>([])
  const boxRef = React.useRef<HTMLPreElement>(null)
  const [follow, setFollow] = React.useState(true)

  React.useEffect(() => {
    if (!container) return
    setLines([])
    const src = new EventSource(api.logsURL(container))
    src.onmessage = (e) => setLines((prev) => [...prev.slice(-2000), e.data])
    src.onerror = () => {
      setLines((prev) => [...prev, "[stream ended]"])
      src.close()
    }
    return () => src.close()
  }, [container])

  React.useEffect(() => {
    if (follow && boxRef.current) boxRef.current.scrollTop = boxRef.current.scrollHeight
  }, [lines, follow])

  return (
    <Dialog open={!!container} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-4xl">
        <DialogHeader>
          <DialogTitle className="font-mono">
            logs: {label || container}
            <span className="text-muted-foreground ml-2 text-xs font-normal">
              last 100 lines, then live
            </span>
          </DialogTitle>
        </DialogHeader>
        <pre ref={boxRef} className="term bg-background h-[55vh] rounded-md border p-3">
          {lines.length ? lines.join("\n") : "connecting…"}
        </pre>
        <div className="flex items-center gap-2">
          <Button
            size="xs"
            variant={follow ? "secondary" : "outline"}
            onClick={() => setFollow((f) => !f)}
          >
            {follow ? "Following" : "Paused"}
          </Button>
          <span className="text-muted-foreground text-xs">{lines.length} lines</span>
        </div>
      </DialogContent>
    </Dialog>
  )
}
