import * as React from "react"

// One browser signal shared by polling and live streams. Treat unknown
// visibility (SSR/test DOMs) as visible; browsers explicitly report hidden.
export function usePageVisible() {
  const [visible, setVisible] = React.useState(() => document.visibilityState !== "hidden")
  React.useEffect(() => {
    const update = () => setVisible(document.visibilityState !== "hidden")
    document.addEventListener("visibilitychange", update)
    update()
    return () => document.removeEventListener("visibilitychange", update)
  }, [])
  return visible
}
