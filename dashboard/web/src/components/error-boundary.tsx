import * as React from "react"

/**
 * Paints the error into the page instead of leaving a blank one.
 *
 * This exists because the first deployment of this app rendered nothing at
 * all, and a blank page carries no information: the operator cannot tell a
 * failed script from a failed fetch from an empty response, and neither can
 * anyone reading a screenshot of it. Anything that throws during render now
 * says what and where.
 */
export class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { error: Error | null }
> {
  state = { error: null as Error | null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    // Still logged, so the browser console keeps the full stack.
    console.error("dashboard render failed:", error, info.componentStack)
  }

  render() {
    if (!this.state.error) return this.props.children
    return (
      <div style={{ padding: 24, fontFamily: "ui-monospace, monospace", lineHeight: 1.5 }}>
        <h1 style={{ fontSize: 16, marginBottom: 8 }}>The dashboard failed to render.</h1>
        <p style={{ marginBottom: 12, fontSize: 13 }}>
          The server is probably fine: this is a fault in the page itself. The text below is what
          to report, and the API is still reachable directly, for example <code>/api/state</code>.
        </p>
        <pre style={{ whiteSpace: "pre-wrap", fontSize: 12, opacity: 0.85 }}>
          {this.state.error.name}: {this.state.error.message}
          {"\n\n"}
          {this.state.error.stack}
        </pre>
      </div>
    )
  }
}
