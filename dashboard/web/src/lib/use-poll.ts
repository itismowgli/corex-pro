import * as React from "react"

/**
 * Fetch on mount, then on an interval, and expose a manual refresh.
 *
 * The old dashboard left every status badge stale until the operator clicked a
 * tab again, which meant a service could come back up and the page kept
 * insisting it was down. Anything showing service state polls.
 *
 * `enabled: false` holds the request back until something asks for it. Every
 * panel used to fetch on mount whether or not its tab was open, and one of
 * those calls shells out to `corex manage storage`, which walks
 * /var/lib/docker and every service directory: measured at 26.7 seconds. So
 * opening the dashboard fired a half-minute request nobody had asked for, on
 * a box where that means a core pinned and the whole page dragging behind it.
 * Panels whose data is expensive now wait to be looked at.
 */
export function usePoll<T>(
  fn: () => Promise<T>,
  intervalMs = 0,
  enabled = true
) {
  const [data, setData] = React.useState<T | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  // Not loading until it is: a panel that has been asked for nothing should
  // not claim to be waiting for something.
  const [loading, setLoading] = React.useState(enabled)
  const fnRef = React.useRef(fn)
  fnRef.current = fn

  const refresh = React.useCallback(async () => {
    try {
      const next = await fnRef.current()
      setData(next)
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  React.useEffect(() => {
    if (!enabled) return
    let live = true
    let timer: number | undefined
    const tick = async () => {
      if (!live) return
      await refresh()
      if (live && intervalMs > 0) timer = window.setTimeout(tick, intervalMs)
    }
    void tick()
    return () => {
      live = false
      if (timer) window.clearTimeout(timer)
    }
  }, [refresh, intervalMs, enabled])

  return { data, error, loading, refresh }
}
