import * as React from "react"
import {
  ArrowDownToLineIcon,
  CopyIcon,
  PauseIcon,
  SearchIcon,
  WrapTextIcon,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { api } from "@/lib/api"
import { parseLine, type Level, type ParsedLine } from "@/lib/logline"
import { cn } from "@/lib/utils"

/**
 * Live container logs over Server-Sent Events.
 *
 * Closing the dialog closes the EventSource, which cancels `docker logs -f` on
 * the server: the subprocess is tied to the request context, so an abandoned
 * stream does not leave one running.
 *
 * The lines are parsed rather than dumped. Every image writes its own format,
 * and rendered as one undifferentiated block they all look equally important,
 * so the error you opened the dialog to find reads exactly like the two
 * hundred routine lines around it.
 */

const LEVEL_STYLE: Record<Level, string> = {
  error: "text-destructive",
  warn: "text-warn",
  info: "text-foreground",
  debug: "text-muted-foreground",
  none: "text-foreground",
}

const LEVEL_LABEL: Record<Level, string> = {
  error: "ERR",
  warn: "WRN",
  info: "INF",
  debug: "DBG",
  none: "",
}

const CAP = 2000

function Line({ line, wrap }: { line: ParsedLine; wrap: boolean }) {
  return (
    <div
      className={cn(
        "flex gap-2 px-2 py-px font-mono text-xs leading-relaxed",
        line.level === "error" && "bg-destructive/10",
        line.level === "warn" && "bg-warn/10"
      )}
    >
      <span className="text-muted-foreground w-14 shrink-0 select-none tabular-nums">
        {line.clock}
      </span>
      <span
        className={cn(
          "w-8 shrink-0 select-none text-[10px] font-semibold",
          LEVEL_STYLE[line.level]
        )}
      >
        {LEVEL_LABEL[line.level]}
      </span>
      <span className={cn("min-w-0", LEVEL_STYLE[line.level], wrap ? "break-all whitespace-pre-wrap" : "truncate")}>
        {line.message}
      </span>
    </div>
  )
}

export function LogsDialog({
  container,
  label,
  onClose,
}: {
  container: string | null
  label: string
  onClose: () => void
}) {
  const [lines, setLines] = React.useState<ParsedLine[]>([])
  const [follow, setFollow] = React.useState(true)
  const [wrap, setWrap] = React.useState(false)
  const [query, setQuery] = React.useState("")
  const [levels, setLevels] = React.useState<Set<Level>>(new Set())
  const [ended, setEnded] = React.useState(false)
  const boxRef = React.useRef<HTMLDivElement>(null)

  React.useEffect(() => {
    if (!container) return
    setLines([])
    setEnded(false)
    const src = new EventSource(api.logsURL(container))
    src.onmessage = (e) =>
      setLines((prev) => {
        const next = prev.length >= CAP ? prev.slice(-CAP + 1) : prev.slice()
        next.push(parseLine(e.data))
        return next
      })
    src.onerror = () => {
      setEnded(true)
      src.close()
    }
    return () => src.close()
  }, [container])

  const shown = React.useMemo(() => {
    const q = query.trim().toLowerCase()
    return lines.filter((l) => {
      if (levels.size && !levels.has(l.level)) return false
      if (!q) return true
      return l.raw.toLowerCase().includes(q)
    })
  }, [lines, query, levels])

  React.useEffect(() => {
    if (follow && boxRef.current) boxRef.current.scrollTop = boxRef.current.scrollHeight
  }, [shown, follow])

  const counts = React.useMemo(() => {
    const c = { error: 0, warn: 0 }
    for (const l of lines) {
      if (l.level === "error") c.error++
      else if (l.level === "warn") c.warn++
    }
    return c
  }, [lines])

  const toggleLevel = (l: Level) =>
    setLevels((prev) => {
      const next = new Set(prev)
      if (next.has(l)) next.delete(l)
      else next.add(l)
      return next
    })

  const copy = () => {
    void navigator.clipboard?.writeText(shown.map((l) => l.raw).join("\n"))
  }

  return (
    <Dialog open={!!container} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-5xl">
        <DialogHeader>
          <DialogTitle className="flex flex-wrap items-center gap-2 text-sm">
            <span className="truncate">{label || container}</span>
            <span className="text-muted-foreground text-xs font-normal">
              last 100 lines, then live
            </span>
            {counts.error > 0 && <Badge variant="destructive">{counts.error} errors</Badge>}
            {counts.warn > 0 && <Badge variant="warn">{counts.warn} warnings</Badge>}
          </DialogTitle>
        </DialogHeader>

        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-40 flex-1">
            <SearchIcon className="text-muted-foreground pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2" />
            <Input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Filter these lines"
              className="h-8 pl-8"
              aria-label="Filter the log"
            />
          </div>
          {(["error", "warn", "info", "debug"] as Level[]).map((l) => (
            <Button
              key={l}
              size="xs"
              variant={levels.has(l) ? "default" : "secondary"}
              onClick={() => toggleLevel(l)}
            >
              {l}
            </Button>
          ))}
          <Button size="xs" variant="secondary" onClick={() => setWrap((v) => !v)}>
            <WrapTextIcon />
            {wrap ? "No wrap" : "Wrap"}
          </Button>
          <Button size="xs" variant="secondary" onClick={() => setFollow((f) => !f)}>
            {follow ? <PauseIcon /> : <ArrowDownToLineIcon />}
            {follow ? "Pause" : "Follow"}
          </Button>
          <Button size="xs" variant="secondary" onClick={copy}>
            <CopyIcon />
            Copy
          </Button>
        </div>

        <div
          ref={boxRef}
          className="bg-background h-[55vh] overflow-auto rounded-md border py-1"
        >
          {shown.length === 0 ? (
            <p className="text-muted-foreground p-3 text-xs">
              {ended
                ? "The stream ended and nothing matched."
                : lines.length
                  ? "Nothing matches that filter."
                  : "Connecting..."}
            </p>
          ) : (
            shown.map((l, i) => <Line key={i} line={l} wrap={wrap} />)
          )}
        </div>

        <div className="text-muted-foreground flex items-center gap-2 text-xs">
          <span>
            {shown.length === lines.length
              ? `${lines.length} lines`
              : `${shown.length} of ${lines.length} lines`}
          </span>
          {lines.length >= CAP && <span>· older lines dropped to keep the tab responsive</span>}
          {ended && <span>· stream ended</span>}
        </div>
      </DialogContent>
    </Dialog>
  )
}
