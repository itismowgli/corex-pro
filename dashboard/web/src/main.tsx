import { StrictMode } from "react"
import { createRoot } from "react-dom/client"

import App from "./App"
import { ErrorBoundary } from "./components/error-boundary"
import "./index.css"

const root = document.getElementById("root")
if (root) {
  // The placeholder in index.html stays visible until React replaces it, so a
  // page that never boots reads as "loading" rather than as nothing at all.
  createRoot(root).render(
    <StrictMode>
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </StrictMode>
  )
}
