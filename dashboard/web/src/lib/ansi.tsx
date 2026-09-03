import * as React from "react"

/**
 * Renders terminal output, keeping its colour.
 *
 * The CoreX commands are written for a terminal and their colour carries the
 * meaning: [  OK] green, [WARN] yellow, [FAIL] red, headings cyan and bold.
 * Stripping the escapes would throw that away and leave a wall of grey text
 * where the important line looks exactly like the others, so the escapes are
 * translated instead.
 *
 * Only SGR sequences are handled, which is all these scripts emit. Anything
 * else is dropped rather than printed, because a stray escape rendered
 * literally is worse than no escape at all.
 */

const FG: Record<number, string> = {
  30: "var(--muted-foreground)",
  31: "var(--destructive)",
  32: "var(--ok)",
  33: "var(--warn)",
  34: "oklch(0.62 0.14 250)",
  35: "oklch(0.65 0.18 320)",
  36: "oklch(0.7 0.11 200)",
  37: "var(--foreground)",
  90: "var(--muted-foreground)",
  91: "var(--destructive)",
  92: "var(--ok)",
  93: "var(--warn)",
  94: "oklch(0.68 0.13 250)",
  95: "oklch(0.7 0.16 320)",
  96: "oklch(0.75 0.1 200)",
  97: "var(--foreground)",
}

type Style = { color?: string; bold?: boolean; underline?: boolean }

const SGR = /\x1b\[([0-9;]*)m/g

export function Ansi({ text, className }: { text: string; className?: string }) {
  const parts = React.useMemo(() => {
    const out: { text: string; style: Style }[] = []
    let style: Style = {}
    let last = 0
    SGR.lastIndex = 0
    let m: RegExpExecArray | null
    const push = (t: string) => {
      if (t) out.push({ text: t, style: { ...style } })
    }
    while ((m = SGR.exec(text)) !== null) {
      push(text.slice(last, m.index))
      last = m.index + m[0].length
      for (const raw of (m[1] || "0").split(";")) {
        const code = Number(raw || "0")
        if (code === 0) style = {}
        else if (code === 1) style.bold = true
        else if (code === 4) style.underline = true
        else if (code === 22) style.bold = false
        else if (code === 24) style.underline = false
        else if (code === 39) delete style.color
        else if (FG[code]) style.color = FG[code]
      }
    }
    push(text.slice(last))
    // Any escape this does not understand, such as cursor movement, would
    // otherwise show up as literal bracket noise.
    return out.map((p) => ({ ...p, text: p.text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "") }))
  }, [text])

  return (
    <pre className={className}>
      {parts.map((p, i) => (
        <span
          key={i}
          style={{
            color: p.style.color,
            fontWeight: p.style.bold ? 600 : undefined,
            textDecoration: p.style.underline ? "underline" : undefined,
          }}
        >
          {p.text}
        </span>
      ))}
    </pre>
  )
}
