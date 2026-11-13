/**
 * Accessibility rules the rendered page has to meet, run by render-check.mjs
 * against every section.
 *
 * These are the structural ones a DOM without layout can answer: does every
 * control have a name a screen reader can say, does every field have a label,
 * is there one page heading and a main landmark to jump to. Contrast and
 * focus order need a real browser and are not claimed here.
 *
 * The rules are written out, not pulled in from a library, for the reason the
 * other checks in this directory are: each one is a mistake that was in the
 * tree when the rule was added, and a failure names the element.
 */

function describe(el) {
  const html = el.outerHTML.replace(/\s+/g, " ")
  return html.length > 160 ? html.slice(0, 160) + "..." : html
}

function labelledBy(el, doc) {
  const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean)
  return ids.map((id) => doc.getElementById(id)?.textContent || "").join(" ").trim()
}

/** The name assistive technology would announce, near enough for a check. */
function accessibleName(el, doc) {
  const direct = (el.getAttribute("aria-label") || "").trim() || labelledBy(el, doc)
  if (direct) return direct
  const text = (el.textContent || "").trim()
  if (text) return text
  const img = el.querySelector("img[alt]")
  if (img && img.getAttribute("alt").trim()) return img.getAttribute("alt").trim()
  const svgTitle = el.querySelector("svg title")
  if (svgTitle && svgTitle.textContent.trim()) return svgTitle.textContent.trim()
  return (el.getAttribute("title") || "").trim()
}

function fieldLabel(el, doc) {
  const direct = (el.getAttribute("aria-label") || "").trim() || labelledBy(el, doc)
  if (direct) return direct
  if (el.id) {
    for (const l of doc.querySelectorAll("label")) {
      if (l.getAttribute("for") === el.id && l.textContent.trim()) return l.textContent.trim()
    }
  }
  const wrap = el.closest("label")
  if (wrap && wrap.textContent.trim()) return wrap.textContent.trim()
  return ""
}

export function a11yFailures(doc) {
  const out = []
  const hidden = (el) => el.closest("[aria-hidden='true'], [hidden], [inert]") !== null

  const controls = doc.querySelectorAll(
    "button, a[href], [role='button'], [role='switch'], [role='tab'], [role='checkbox'], [role='menuitem']"
  )
  for (const el of controls) {
    if (hidden(el)) continue
    if (!accessibleName(el, doc)) out.push("a control with no name: " + describe(el))
  }

  for (const el of doc.querySelectorAll("input, select, textarea")) {
    if (hidden(el) || el.type === "hidden") continue
    if (!fieldLabel(el, doc)) out.push("a field with no label: " + describe(el))
  }

  for (const el of doc.querySelectorAll("img")) {
    if (!el.hasAttribute("alt")) out.push("an image with no alt: " + describe(el))
  }

  // A switch that does not say which way it is set. A native checkbox
  // carries its own state, so only a hand-built one has to declare it.
  for (const el of doc.querySelectorAll("[role='switch']")) {
    const native = el.tagName === "INPUT" && el.type === "checkbox"
    if (!native && !el.hasAttribute("aria-checked")) {
      out.push("a switch with no state: " + describe(el))
    }
  }

  const h1 = doc.querySelectorAll("h1")
  if (h1.length !== 1) out.push("expected one h1, found " + h1.length)

  if (!doc.querySelector("main, [role='main']")) out.push("no main landmark")
  if (!doc.querySelector("nav, [role='navigation']")) out.push("no navigation landmark")

  // A way past the navigation for a keyboard, which has to be the first
  // thing focus reaches.
  const first = doc.querySelector("#root a[href], #root button")
  if (!first || !/^#/.test(first.getAttribute("href") || "")) {
    out.push("the first focusable element is not a skip link to the content")
  } else if (!doc.getElementById(first.getAttribute("href").slice(1))) {
    out.push("the skip link points at " + first.getAttribute("href") + ", which is not on the page")
  }

  // Two different things with the same id break every label that names one.
  const seen = new Set()
  for (const el of doc.querySelectorAll("[id]")) {
    if (seen.has(el.id)) out.push("duplicate id " + JSON.stringify(el.id))
    seen.add(el.id)
  }

  if (!doc.documentElement.getAttribute("lang")) out.push("the page does not declare a language")
  return out
}
