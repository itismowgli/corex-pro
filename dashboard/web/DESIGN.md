# The CoreX dashboard design system

Every rule here is enforced by `design-check.mjs`, which runs in the build.
A rule nothing checks is a rule that lasts until the next hurried change, and
this file exists because the dashboard had grown four type sizes that were not
in any scale, three transition durations, and colours written as literals in
six components.

The target is a dense control surface that reads calmly: the chrome recedes
and the numbers do not. That means a narrow palette, a small type scale, and
motion short enough that nothing is ever waited on.

## Colour

One neutral ramp, one accent, three state colours. Nothing else.

**The governing idea: on a status panel, colour is a reading. Chrome gets
none.** The accent is not greyscale and the chrome is not bright. It was the
other way round, and the result was that the four brightest objects on the
Services page were its switches, because `--primary` was a near-white grey and
the switch used it. The green that meant healthy and the red that meant down
were quieter than a toggle.

| Token | Use |
|---|---|
| `background`, `foreground` | the page |
| `card`, `card-foreground` | any raised surface |
| `muted`, `muted-foreground` | secondary text, inert fills |
| `border`, `input`, `ring` | edges and focus |
| `primary` | the one accent, for the single most important action in a view |
| `selected` | the raised surface under a chosen segment. Never `primary` |
| `ok` | a thing that is working, and nothing else |
| `warn` | deliberate, or degraded but not broken |
| `destructive` | broken, or an action that destroys |
| `seg-*` | the four storage roles, used only by the storage map |

**Rules**

1. A component never writes a colour literal. No hex, no `rgb(`, no `oklch(`
   outside `index.css`. The check fails the build on any of them.
2. State colour marks state, never decoration. A green border because green
   looks nice is how `ok` stops meaning "this is working".
3. One accent per view. If two things are primary, neither is. The Updates
   page spends it on Update everything, so every per service Update is
   secondary, and Upgrade Ubuntu is an outline: it is the one action that can
   leave the machine unbootable, so it is offered rather than invited.
4. Contrast comes from the foreground pair that belongs to the surface. Do not
   put `foreground` on `card` and hope.
5. **Selection is not an action, so it never borrows the accent.** A chosen
   filter rendered as the page's one accent reads as the thing to press next,
   which is exactly backwards. Choices go through `Segmented`, or through the
   button's `toggle` variant when several can be on at once, and both use
   `selected`. There were three competing idioms before that and the loudest
   of them was attached to the least important decision on the screen.
6. A component never writes `bg-primary` or `text-primary-foreground`. Only
   `components/ui/` spends the accent, so there is one place to count the
   uses. `design-check.mjs` fails the build on any other file.

## Type

Five sizes. A sixth is a bug.

| Token | Size | Line | Use |
|---|---|---|---|
| `--text-micro` | 11px | 16px | metadata, table labels, units |
| `--text-small` | 12px | 18px | secondary text, captions, help |
| `--text-body` | 13px | 20px | the default for everything |
| `--text-title` | 15px | 22px | card and section titles |
| `--text-display` | 18px | 26px | the page heading, once per page |

Numbers that are compared to each other are tabular: `font-variant-numeric:
tabular-nums`, which is what `.num` applies. A column of figures that jitters
as it updates is unreadable, and every vital on this page updates.

**Rules**

7. Only these five. No `text-[13px]`, no `text-2xl`.
8. Weight is 400 or 500. 600 only in `--text-display`. Bold is not emphasis
   here, colour and placement are.

## Space

A 4px grid. Tailwind's `1` = 4px, so use its scale and nothing arbitrary.

**Rules**

9. No arbitrary spacing: no `p-[7px]`, no `gap-[13px]`.
10. Dense by default. Card padding is `3` (12px), gaps inside a card are `2`,
   gaps between cards are `3`. A control surface is not a marketing page.

## Radius

| Token | Value | Use |
|---|---|---|
| `--radius-sm` | 4px | badges, inputs, small controls |
| `--radius-md` | 6px | buttons |
| `--radius-lg` | 8px | cards, dialogs, popovers |

**Rules**

11. Only these three. The old value was 14px, which made every panel read as a
   separate rounded box rather than one surface.

## Motion

| Token | Value | Use |
|---|---|---|
| `--dur-fast` | 90ms | hover, focus, press |
| `--dur` | 140ms | open, close, reveal |
| `--ease` | `cubic-bezier(0.2, 0, 0, 1)` | everything |

**Rules**

12. Only these two durations and that one easing. No `duration-300`, no
    `ease-in-out`, no spring.
13. Nothing bounces and nothing travels more than 4px. Motion confirms that
    something happened; it is not the thing that happened.
14. Anything that can take longer than a frame shows its state in place rather
    than replacing the view with a spinner. A layout that disappears while it
    reloads is why a fast page feels slow.

## Elevation

Two levels, both nearly invisible.

| Token | Use |
|---|---|
| `--shadow-sm` | a card against the page |
| `--shadow-md` | something over the page: dialog, popover, drawer |

**Rules**

15. A surface has a border or a shadow, never both on the same edge.

## Density and layout

16. The content column is capped and the chrome is fixed. Nothing reflows when
    a number changes width.
17. Every interactive element is at least 32px on its smallest axis for
    pointer targets, and the hit area may exceed the painted area.

## What the check enforces

`design-check.mjs` reads `src/` and fails on:

- a colour literal outside `index.css`
- the accent written by hand outside `components/ui/`
- an arbitrary Tailwind value for size, spacing, or radius (`-[...]`)
- a type size outside the five
- a transition duration or easing outside the tokens
- a `rounded-*` outside the three steps

It cannot check taste. It can check that the vocabulary stays small, which is
most of what a design system is.

## Looking at it

`shot.mjs` renders the built app in a real browser, from the same fixtures
every other check uses, and writes a PNG per screen per theme. It is not part
of the build and playwright is deliberately not a dependency; the header of
that file says how to install it out of tree.

Use it. `render-check.mjs` proves a panel rendered its data and cannot see that
a control is the loudest thing on a page it has no business leading. Every fix
in the colour and selection rules above was found by looking at a screenshot,
not by reading the code, and each one passed every check in the build while it
was wrong.
