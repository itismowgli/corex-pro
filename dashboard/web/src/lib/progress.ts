/**
 * Turning an update's raw output into per-service progress.
 *
 * `corex manage update <svc>` runs `docker compose pull` and then `up -d`, and
 * both report per line. That output already says how far along a pull is, one
 * layer at a time, so the progress here is read from it rather than invented:
 * there is no second source to disagree with, which is the mistake gotcha #50
 * is about.
 *
 * Parsed against output this box actually produces, for the reason in gotcha
 * #38. `progress-check.mjs` runs those shapes in the build.
 */

export type UpdatePhase = "starting" | "pulling" | "restarting" | "done" | "failed"

export type UpdateProgress = {
  phase: UpdatePhase
  /** One short line for a card, already written for a human. */
  detail: string
  /** 0 to 100 while the layer count is known, otherwise null. */
  pct: number | null
}

const ANSI = new RegExp(String.fromCharCode(27) + "\\[[0-9;]*m", "g")

/**
 * A layer is named by a short hex id and a service by its name, and both
 * appear in front of the word "Pulling". Counting the service as a layer puts
 * the denominator out by one, which makes a single-layer pull read as 50%.
 */
function isLayerId(s: string): boolean {
  return s.length >= 10 && /^[0-9a-f]+$/.test(s)
}

const DONE_STATES = new Set(["Pull complete", "Already exists"])

const LAYER_STATES = [
  "Pulling fs layer",
  "Waiting",
  "Downloading",
  "Verifying Checksum",
  "Download complete",
  "Extracting",
  "Pull complete",
  "Already exists",
]

export function updateProgress(output: string): UpdateProgress {
  const text = (output || "").replace(ANSI, "")

  const layers = new Map<string, string>()
  // Images are the honest unit of progress. A stack can hold several, and a
  // pull that finishes quickly prints no layer line that ever reaches "Pull
  // complete", so counting layers alone reports 0% on a completed pull.
  // Measured: a three line run that pulled alpine in full.
  const pulling = new Set<string>()
  const pulled = new Set<string>()
  let container: string | null = null
  let containerState: string | null = null
  let failed = false

  for (const raw of text.split("\n")) {
    const line = raw.trimEnd()
    if (!line.trim()) continue

    if (/\[FAIL\]|pull failed|did not come up|Error response from daemon/i.test(line)) {
      failed = true
    }

    // " Container immich-server Recreated"
    const c = line.match(
      /Container\s+(\S+)\s+(Recreated|Created|Starting|Started|Healthy|Waiting|Stopping|Stopped|Running)\s*$/,
    )
    if (c) {
      container = c[1]
      containerState = c[2]
      continue
    }

    // " Image authelia/authelia:4.39 Pulled". Compose names the image here,
    // not the service, which the first version of this parser assumed and so
    // matched none of it.
    const img = line.match(/^\s*Image\s+(\S+)\s+(Pulling|Pulled|Skipped|Error|Warning)\b/)
    if (img) {
      if (img[2] === "Pulling") pulling.add(img[1])
      else if (img[2] === "Pulled" || img[2] === "Skipped") {
        pulling.add(img[1])
        pulled.add(img[1])
      } else if (img[2] === "Error") failed = true
      continue
    }

    // " 17a39c0ba978 Downloading 1.049MB"
    for (const st of LAYER_STATES) {
      const m = line.match(new RegExp("^\\s*(\\S+)\\s+" + st + "\\b"))
      if (m && isLayerId(m[1])) {
        layers.set(m[1], st)
        break
      }
    }
  }

  if (failed) {
    return { phase: "failed", detail: "The update did not finish.", pct: null }
  }

  // Container lines come after the pull, so they win when both appear.
  if (containerState) {
    const done =
      containerState === "Started" || containerState === "Running" || containerState === "Healthy"
    return {
      phase: done ? "done" : "restarting",
      detail: container + " " + containerState.toLowerCase(),
      pct: done ? 100 : null,
    }
  }

  if (pulling.size > 0) {
    const pct = Math.round((pulled.size / pulling.size) * 100)
    if (pulled.size === pulling.size) {
      return { phase: "restarting", detail: "Images ready, restarting", pct: 100 }
    }
    // With one image the layer count is the more useful line; with several,
    // naming one image out of five reads as though the rest were skipped,
    // which is the wording trap in gotcha #26.
    const layerDone = [...layers.values()].filter((s) => DONE_STATES.has(s)).length
    const detail =
      pulling.size > 1
        ? pulled.size + " of " + pulling.size + " images ready"
        : layers.size > 0
          ? layerDone + " of " + layers.size + " layer" + (layers.size === 1 ? "" : "s") + " ready"
          : "Asking the registry"
    return { phase: "pulling", detail, pct }
  }

  if (layers.size > 0) {
    const doneCount = [...layers.values()].filter((s) => DONE_STATES.has(s)).length
    return {
      phase: "pulling",
      detail: doneCount + " of " + layers.size + " layer" + (layers.size === 1 ? "" : "s") + " ready",
      pct: Math.round((doneCount / layers.size) * 100),
    }
  }

  return { phase: "starting", detail: "Starting", pct: null }
}

/**
 * Which service a combined "update all" run is currently working on.
 *
 * The run prints "Updating <svc>..." before each one, so the last such line
 * names the service the output after it belongs to. Without this the whole
 * run is one opaque block and no card can show anything of its own.
 */
export function currentTarget(output: string): string | null {
  const text = (output || "").replace(ANSI, "")
  let found: string | null = null
  for (const line of text.split("\n")) {
    const m = line.match(/Updating\s+(\S+?)\.\.\./)
    if (m && m[1] !== "all") found = m[1]
  }
  return found
}

/** The output produced since the named service's section began. */
export function sliceFor(output: string, service: string): string {
  const text = (output || "").replace(ANSI, "")
  const i = text.lastIndexOf("Updating " + service + "...")
  return i < 0 ? text : text.slice(i)
}
