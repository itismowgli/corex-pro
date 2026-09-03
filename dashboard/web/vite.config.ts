import path from "path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// The Go binary embeds dist/ and serves it, so assets are referenced from the
// site root and nothing is fetched at runtime. Everything, including the
// fonts and icons, ends up inside the binary: the dashboard has to work on a
// box whose tunnel is down, which is exactly when someone needs it.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Vite's default target is whatever is "baseline widely available", which
    // is newer than the browser on someone's phone or an older Safari. A
    // module the browser cannot parse is a SyntaxError before any of our code
    // runs, which is a blank page with only a console entry to show for it.
    // This is an admin page, not a demo; reach is worth more than bytes.
    target: ["es2020", "chrome90", "firefox90", "safari14", "edge90"],
    // One JS and one CSS file rather than a graph of chunks: there is no code
    // splitting worth having in a four-tab admin page.
    //
    // The names keep their content hash, which is not cosmetic. The first
    // version of this fixed the names as assets/app.js while the server sent
    // `Cache-Control: immutable, max-age=31536000` for everything under
    // assets/, and those two together pin the first build forever. Cloudflare
    // held the old bundle (cf-cache-status: HIT, age 1040) and served it
    // alongside the new index.html, so the fix for a blank page could not
    // reach the browser that needed it, and no amount of redeploying would
    // have changed that. A hash in the name is what makes immutable true.
    rollupOptions: {
      output: {
        manualChunks: undefined,
      },
    },
  },
  server: {
    // For `npm run dev` against a real box: point the API at it.
    proxy: { "/api": process.env.COREX_DEV_API || "http://localhost:8080" },
  },
})
