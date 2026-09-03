import * as React from "react"

/**
 * Subscribe to a Server-Sent Events endpoint that pushes JSON.
 *
 * Polling showed numbers up to twenty seconds old, which for a temperature on
 * hardware that trips at TjMax is the wrong kind of stale. The browser
 * reconnects an EventSource on its own, so the only thing this adds is
 * decoding, a live flag for the page to show, and a guard against setting
 * state after unmount.
 */
export function useStream<T>(url: string, enabled = true) {
  const [data, setData] = React.useState<T | null>(null)
  const [live, setLive] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  React.useEffect(() => {
    if (!enabled) return
    let alive = true
    const src = new EventSource(url)
    src.onopen = () => alive && setLive(true)
    src.onmessage = (e) => {
      if (!alive) return
      try {
        setData(JSON.parse(e.data) as T)
        setError(null)
        setLive(true)
      } catch {
        // A malformed frame is not worth tearing the stream down for; the
        // next one is five seconds away.
      }
    }
    src.onerror = () => {
      if (!alive) return
      // EventSource retries by itself, so this is "not connected right now"
      // rather than "give up". Saying so is the difference between a stale
      // number and a number the reader knows is stale.
      setLive(false)
      setError("reconnecting")
    }
    return () => {
      alive = false
      src.close()
    }
  }, [url, enabled])

  return { data, live, error }
}
