import * as React from "react"
import { Loader2Icon, PlayIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Ansi } from "@/lib/ansi"

/**
 * One box-wide command: a button, and its output where you can read it.
 *
 * The output is the command's own, colour and alignment intact, rather than a
 * summary of it. That is deliberate: these commands are the source of truth
 * for the CLI too, and a dashboard that paraphrases them is a second place
 * for the answer to be wrong.
 */
export function CommandPanel({
  title,
  description,
  action,
  icon: Icon = PlayIcon,
  buttonLabel = "Run",
  variant = "secondary",
  confirm,
  output,
  running,
  locked,
  onRun,
  children,
}: {
  title: string
  description?: React.ReactNode
  action: string
  icon?: typeof PlayIcon
  buttonLabel?: string
  variant?: "secondary" | "outline" | "destructive"
  confirm?: string
  output?: string
  running?: boolean
  // The agent runs one job at a time and refuses the rest with "busy running
  // X". Disabling every button while any job runs is clearer than letting the
  // click through to that refusal.
  locked?: boolean
  onRun: (action: string) => void
  children?: React.ReactNode
}) {
  const click = () => {
    if (confirm && !window.confirm(confirm)) return
    onRun(action)
  }
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
          <Icon className="size-4" />
          {title}
          <Button
            size="xs"
            variant={variant}
            className="ml-auto"
            disabled={running || locked}
            onClick={click}
          >
            {running ? <Loader2Icon className="animate-spin" /> : <Icon />}
            {running ? "Running" : buttonLabel}
          </Button>
        </CardTitle>
        {description && (
          <div className="text-muted-foreground text-xs leading-relaxed">{description}</div>
        )}
      </CardHeader>
      {(output || children) && (
        <CardContent className="flex flex-col gap-2">
          {children}
          {output && (
            <Ansi
              text={output}
              className="term bg-background max-h-[55vh] rounded-md border p-3"
            />
          )}
        </CardContent>
      )}
    </Card>
  )
}
