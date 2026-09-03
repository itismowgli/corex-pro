import * as React from "react"
import { CheckCircle2Icon, Loader2Icon, XCircleIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { api, type Job } from "@/lib/api"
import { cn } from "@/lib/utils"

/**
 * One place where every action reports what it did.
 *
 * Actions are asynchronous because repair and update outlast any sensible
 * request timeout, and a button that appears to hang is how you end up
 * clicking it twice. The panel polls the job and then tells the page to
 * refresh its statuses, which the previous dashboard deliberately did not do
 * and so always showed stale badges after an action.
 */
export function JobPanel({
  job,
  setJob,
  onFinished,
}: {
  job: Job | null
  setJob: (j: Job | null) => void
  onFinished: (finished: Job) => void
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

  if (!job) return null

  const running = job.state === "running"
  const failed = job.state === "failed"

  return (
    <Card className="border-l-4" data-state={job.state}>
      <CardHeader className="flex-row items-center gap-2">
        {running ? (
          <Loader2Icon className="text-muted-foreground size-4 animate-spin" />
        ) : failed ? (
          <XCircleIcon className="text-destructive size-4" />
        ) : (
          <CheckCircle2Icon className="text-ok size-4" />
        )}
        <CardTitle className="font-mono text-sm">
          {job.label || "job"}
          <span className="text-muted-foreground ml-2 font-sans text-xs font-normal">
            {running ? "running, this updates on its own" : job.state}
          </span>
        </CardTitle>
        <div className="ml-auto flex gap-2">
          {!running && (
            <Button size="xs" variant="ghost" onClick={() => setJob(null)}>
              Dismiss
            </Button>
          )}
        </div>
      </CardHeader>
      <CardContent>
        <pre
          className={cn(
            "term bg-background max-h-64 rounded-md border p-3",
            failed && "text-destructive"
          )}
        >
          {job.output?.trim() ? job.output : running ? "waiting for output…" : "(no output)"}
        </pre>
      </CardContent>
    </Card>
  )
}
