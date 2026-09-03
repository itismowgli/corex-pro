import * as React from "react"
import { CheckCircle2Icon, ChevronDownIcon, Loader2Icon, XCircleIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Ansi } from "@/lib/ansi"
import { api, type Job } from "@/lib/api"
import { cn } from "@/lib/utils"

/**
 * A strip that says what is running and how it went.
 *
 * Actions are asynchronous because repair and update outlast any sensible
 * request timeout, and a button that appears to hang is how you end up
 * clicking it twice. The panel polls the job and then tells the page to
 * refresh its statuses, which the previous dashboard did not do and so always
 * showed stale badges after an action.
 *
 * It used to print the whole output here as well, which meant running a
 * hardware check showed the identical report twice on one screen, once in this
 * panel and once in the tab that asked for it. The output belongs to the tab
 * that asked; this says whether it worked. `hasHome` is how the panel knows
 * the difference: an action whose output has a home shows only the outcome
 * line, and anything else keeps its output here so it is not lost.
 */

/**
 * The last meaningful line of a run.
 *
 * corex-manage already prints a summary saying what changed, and that single
 * sentence is what the reader wants from a strip. On failure it is the tail,
 * because that is where the error is.
 */
function outcomeOf(output: string, failed: boolean): string {
  const lines = output
    .split("\n")
    .map((l) => l.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").trim())
    .filter(Boolean)
  if (!lines.length) return ""
  if (failed) return lines[lines.length - 1]
  const ok = lines.filter((l) => l.startsWith("[  OK]"))
  const chosen = ok.length ? ok[ok.length - 1] : lines[lines.length - 1]
  return chosen.replace(/^\[(\s*OK|INFO|STEP|WARN|FAIL)\]\s*/, "")
}
export function JobPanel({
  job,
  setJob,
  onFinished,
  hasHome,
}: {
  job: Job | null
  setJob: (j: Job | null) => void
  onFinished: (finished: Job) => void
  /** True when the tab below already shows this job's output in full. */
  hasHome: boolean
}) {
  const finishedRef = React.useRef(false)

  React.useEffect(() => {
    if (!job || job.state !== "running" || !job.id) return
    finishedRef.current = false
    let live = true
    const poll = async () => {
      if (!live) return
      try {
        const next = await api.job(job.id)
        if (!live) return
        setJob(next)
        if (next.state === "running") {
          window.setTimeout(poll, 2000)
        } else if (!finishedRef.current) {
          finishedRef.current = true
          onFinished(next)
        }
      } catch (e) {
        if (!live) return
        setJob({
          ...job,
          state: "failed",
          output: e instanceof Error ? e.message : String(e),
        })
      }
    }
    const t = window.setTimeout(poll, 1500)
    return () => {
      live = false
      window.clearTimeout(t)
    }
  }, [job, setJob, onFinished])

  const [open, setOpen] = React.useState(false)

  if (!job) return null

  const running = job.state === "running"
  const failed = job.state === "failed"
  const output = job.output ?? ""
  const outcome = outcomeOf(output, failed)

  return (
    <Card className="gap-2 border-l-4 py-3" data-state={job.state}>
      <CardContent className="grid gap-2 px-3">
        <div className="flex flex-wrap items-center gap-2">
          {running ? (
            <Loader2Icon className="text-muted-foreground size-4 shrink-0 animate-spin" />
          ) : failed ? (
            <XCircleIcon className="text-destructive size-4 shrink-0" />
          ) : (
            <CheckCircle2Icon className="text-ok size-4 shrink-0" />
          )}
          <span className="min-w-0 text-sm font-medium">{job.label || "Working"}</span>
          <span
            className={cn(
              "text-muted-foreground min-w-0 flex-1 truncate text-xs",
              failed && "text-destructive"
            )}
            title={outcome}
          >
            {running ? "running, this updates on its own" : outcome || job.state}
          </span>
          <span className="ml-auto flex shrink-0 gap-1">
            {output.trim() && (
              <Button size="xs" variant="ghost" onClick={() => setOpen((v) => !v)}>
                <ChevronDownIcon className={cn("transition-transform", open && "rotate-180")} />
                {open ? "Hide" : hasHome ? "Output" : "Details"}
              </Button>
            )}
            {!running && (
              <Button size="xs" variant="ghost" onClick={() => setJob(null)}>
                Dismiss
              </Button>
            )}
          </span>
        </div>

        {/* Collapsed by default when the tab below is already showing this
            output. Expanded on failure regardless, because a failure is the
            one case where nobody should have to click to find out why. */}
        {(open || (failed && !hasHome)) && output.trim() && (
          <Ansi
            text={output}
            className="term bg-background max-h-64 overflow-auto rounded-md border p-3"
          />
        )}
      </CardContent>
    </Card>
  )
}
