import { Bullet } from "@microcharts/react/bullet"

import { cn } from "@/lib/utils"

/**
 * A value against the thresholds that act on it.
 *
 * The thermal numbers were a sentence: "Warns at 80C, sheds load at 85C,
 * hardware cuts power around 97C." That is three numbers and a reading, and
 * working out which band you are in is left to the reader, on the one measure
 * this hardware actually fails by (gotcha #17).
 *
 * The chart is `@microcharts/react`, which is the only dependency this
 * dashboard's UI has taken. It is compatible with the rule in `spark.tsx`
 * rather than an exception to it: that rule is about fetching at runtime
 * (gotcha #35), and this is bundled into the same binary by Vite, so the page
 * still asks the network for nothing. Its stylesheet is imported in
 * `index.css` for the same reason.
 *
 * Spark still draws every time series here. This covers the shape Spark
 * cannot: one value placed among qualitative bands.
 */
export function BandGauge({
  value,
  bands,
  max,
  title,
  className,
}: {
  value: number
  /** Ascending thresholds, for example [80, 85, 97]. */
  bands: number[]
  max: number
  title: string
  className?: string
}) {
  return (
    <Bullet
      value={value}
      bands={bands}
      domain={[0, max]}
      label="value"
      title={title}
      className={cn("w-full", className)}
    />
  )
}
