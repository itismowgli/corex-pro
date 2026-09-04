import * as React from "react"
import * as DialogPrimitive from "@radix-ui/react-dialog"
import { XIcon } from "lucide-react"

import { cn } from "@/lib/utils"

/**
 * A panel that slides in from the edge, built on the dialog primitive that is
 * already here rather than a second dependency.
 *
 * It exists for one job: the navigation on a phone. The sidebar is a fixed
 * column on a wide screen and there is no room for that on a 360px display,
 * so it becomes a drawer opened from the header. Radix supplies the focus
 * trap and the escape key, which is the part that is easy to get wrong and
 * the part that decides whether the nav can be dismissed at all.
 */
const Sheet = (props: React.ComponentProps<typeof DialogPrimitive.Root>) => (
  <DialogPrimitive.Root data-slot="sheet" {...props} />
)

function SheetContent({
  className,
  children,
  title,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Content> & { title: string }) {
  return (
    <DialogPrimitive.Portal>
      <DialogPrimitive.Overlay className="data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/60" />
      <DialogPrimitive.Content
        data-slot="sheet-content"
        className={cn(
          "bg-card data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:slide-out-to-left data-[state=open]:slide-in-from-left fixed inset-y-0 left-0 z-50 flex w-[17rem] max-w-[85vw] flex-col border-r shadow-lg",
          className
        )}
        {...props}
      >
        {/* Radix requires a title for the dialog to be announced. It is the
            section name, which a sighted user reads from the nav itself. */}
        <DialogPrimitive.Title className="sr-only">{title}</DialogPrimitive.Title>
        {children}
        <DialogPrimitive.Close className="focus-visible:ring-ring/50 absolute top-3.5 right-3 rounded-md p-1 opacity-70 transition-opacity hover:opacity-100 focus-visible:ring-[3px] focus-visible:outline-none">
          <XIcon className="size-4" />
          <span className="sr-only">Close</span>
        </DialogPrimitive.Close>
      </DialogPrimitive.Content>
    </DialogPrimitive.Portal>
  )
}

export { Sheet, SheetContent }
