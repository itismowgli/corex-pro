import { EraserIcon, HardDriveIcon, SearchIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"

export function StorageTab({
  output,
  loading,
  error,
  busy,
  onCleanup,
}: {
  output: string
  loading: boolean
  error: string | null
  busy: boolean
  onCleanup: (dryRun: boolean) => void
}) {
  return (
    <div className="flex flex-col gap-3">
      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2 text-sm">
            <HardDriveIcon className="size-4" />
            Disk usage by service
            <span className="ml-auto flex gap-2">
              <Button size="xs" variant="secondary" disabled={busy} onClick={() => onCleanup(true)}>
                <SearchIcon />
                Preview cleanup
              </Button>
              <Button
                size="xs"
                variant="outline"
                disabled={busy}
                onClick={() => {
                  if (
                    window.confirm(
                      "Remove stale images and build cache? No service data is deleted."
                    )
                  )
                    onCleanup(false)
                }}
              >
                <EraserIcon />
                Run cleanup
              </Button>
            </span>
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading ? (
            <Skeleton className="h-48" />
          ) : (
            <pre className="term bg-background max-h-[60vh] rounded-md border p-3">
              {output?.trim() ||
                error ||
                "No storage report. corex-manage.sh storage returned nothing."}
            </pre>
          )}
        </CardContent>
      </Card>
      <p className="text-muted-foreground text-xs">
        Cleanup removes images unused for 7 days or more and build cache older than 3 days. It
        never touches service data, and it never runs a volume prune.
      </p>
    </div>
  )
}
