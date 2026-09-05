import * as React from "react"
import { usePageVisible } from "./use-page-visible"

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
  const visible = usePageVisible()
  const active = enabled && visible
  const [data, setData] = React.useState<T | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  // Not loading until it is: a panel that has been asked for nothing should
  // not claim to be waiting for something.
  const [loading, setLoading] = React.useState(enabled)
  const fnRef = React.useRef(fn)
  fnRef.current = fn

  const generation = React.useRef(0)
  const mounted = React.useRef(false)
  const inFlight = React.useRef<{ generation: number; promise: Promise<void> } | null>(null)

  const refresh = React.useCallback((): Promise<void> => {
    if (!mounted.current) return Promise.resolve()
    const current = generation.current
    if (inFlight.current?.generation === current) return inFlight.current.promise
    setLoading(true)
    const valid = () => mounted.current && generation.current === current
    // Defer invocation so the in-flight entry exists even for a synchronous throw.
    const promise = Promise.resolve().then(() => fnRef.current()).then(
      (next) => {
        if (!valid()) return
        setData(next)
        setError(null)
      },
      (e: unknown) => {
        if (valid()) setError(e instanceof Error ? e.message : String(e))
      }
    ).finally(() => {
      if (valid()) setLoading(false)
      if (inFlight.current?.promise === promise) inFlight.current = null
    })
    inFlight.current = { generation: current, promise }
    return promise
  }, [])

  React.useEffect(() => {
    mounted.current = true
    generation.current += 1
    if (!active) setLoading(false)
    let live = true
    let timer: number | undefined
    const tick = async () => {
      if (!live) return
      await refresh()
      if (live && intervalMs > 0) timer = window.setTimeout(tick, intervalMs)
    }
    if (active) void tick()
    return () => {
      live = false
      mounted.current = false
      generation.current += 1
      if (timer) window.clearTimeout(timer)
    }
  }, [refresh, intervalMs, active])

  return { data, error, loading, refresh }
}
