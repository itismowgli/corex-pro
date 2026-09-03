import * as React from "react"

/**
 * Fetch on mount, then on an interval, and expose a manual refresh.
 *
 * The old dashboard left every status badge stale until the operator clicked a
 * tab again, which meant a service could come back up and the page kept
 * insisting it was down. Anything showing service state polls.
 */
export function usePoll<T>(fn: () => Promise<T>, intervalMs = 0) {
  const [data, setData] = React.useState<T | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [loading, setLoading] = React.useState(true)
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
  }, [refresh, intervalMs])

  return { data, error, loading, refresh }
}
