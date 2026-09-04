import {
  CalendarClockIcon,
  GaugeIcon,
  HardDriveIcon,
  HeartPulseIcon,
  LayoutGridIcon,
  MonitorIcon,
  NetworkIcon,
  ServerIcon,
  UserRoundIcon,
  type LucideIcon,
} from "lucide-react"

/**
 * The sections, and the groups they sit in.
 *
 * One list, read by the sidebar, the drawer and the command palette, because
 * a section that exists in the nav and not in the palette is a section nobody
 * finds twice. The grouping is by what you came here to do: watch the box,
 * change what runs on it, look into a number, or administer the machine.
 */
export type NavItem = {
  id: string
  label: string
  icon: LucideIcon
  /** One line in the command palette, where there is no surrounding page to explain the name. */
  hint: string
}

export type NavGroup = { title: string; items: NavItem[] }

const GROUPS: NavGroup[] = [
  {
    title: "Dashboard",
    items: [
      { id: "overview", label: "Overview", icon: GaugeIcon, hint: "Temperature, load, memory and what is consuming them" },
    ],
  },
  {
    title: "Services",
    items: [
      { id: "services", label: "Services", icon: ServerIcon, hint: "Start, stop, repair, update and read logs" },
      { id: "catalogue", label: "Catalogue", icon: LayoutGridIcon, hint: "Everything CoreX can install, and what is installed" },
    ],
  },
  {
    title: "Monitoring",
    items: [
      { id: "health", label: "Health", icon: HeartPulseIcon, hint: "Hardware report, watchdog findings and the doctor" },
      { id: "storage", label: "Storage", icon: HardDriveIcon, hint: "Disks, what fills them, and what can be reclaimed" },
      { id: "network", label: "Network", icon: NetworkIcon, hint: "Addresses, certificates and the LAN fast path" },
    ],
  },
  {
    title: "Machine",
    items: [
      { id: "maintenance", label: "Maintenance", icon: CalendarClockIcon, hint: "The schedule, and what each task last did" },
      { id: "system", label: "System", icon: MonitorIcon, hint: "Host details, published ports, updates and power" },
    ],
  },
]

const ACCOUNT: NavItem = {
  id: "account",
  label: "Account",
  icon: UserRoundIcon,
  hint: "Password, two-factor, passkeys and the access log",
}

/**
 * Account appears only once the dashboard has accounts of its own. Before
 * that there is nothing to manage: Traefik basic auth has no notion of who
 * you are.
 */
export function navGroups(authEnabled: boolean | undefined): NavGroup[] {
  if (!authEnabled) return GROUPS
  return GROUPS.map((g) =>
    g.title === "Machine" ? { ...g, items: [...g.items, ACCOUNT] } : g
  )
}

export function navItems(authEnabled: boolean | undefined): NavItem[] {
  return navGroups(authEnabled).flatMap((g) => g.items)
}

export function navLabel(id: string, authEnabled: boolean | undefined): string {
  return navItems(authEnabled).find((i) => i.id === id)?.label ?? "Overview"
}
