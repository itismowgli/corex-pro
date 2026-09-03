import { ActivityIcon, StethoscopeIcon, ThermometerIcon } from "lucide-react"

import { CommandPanel } from "@/components/command-panel"

/**
 * The half of monitoring an HTTP check cannot cover.
 *
 * A container answering 200 says nothing about the temperature, a disk with
 * SMART errors, a half-configured dpkg database, or a container that is
 * restart-looping. On this class of hardware the most common hardware failure
 * is a thermal trip that logs nothing at all, so these are the numbers that
 * matter most and they were only ever visible over SSH.
 */
export function HealthTab({
  outputs,
  running,
  onRun,
}: {
  outputs: Record<string, string>
  running: string | null
  onRun: (action: string) => void
}) {
  return (
    <div className="flex flex-col gap-3">
      <CommandPanel
        title="Hardware health"
        description={
          <>
            CPU temperature, SMART status per disk, the dpkg state, and whether the last shutdown
            was clean. An unclean shutdown leaves no journal evidence, so this reads the blackbox
            log instead.
          </>
        }
        action="health"
        icon={ThermometerIcon}
        buttonLabel="Check"
        output={outputs.health}
        running={running === "health"}
        onRun={onRun}
      />
      <CommandPanel
        title="Resource watchdog"
        description={
          <>
            Memory, disk, heat and container faults: a container stopped while its restart policy
            says otherwise, one whose restart count is climbing, one that was OOM killed. None of
            those changes an HTTP response, which is why reachability checks miss them.
          </>
        }
        action="watchdog"
        icon={ActivityIcon}
        buttonLabel="Report"
        output={outputs.watchdog}
        running={running === "watchdog"}
        onRun={onRun}
      />
      <CommandPanel
        title="Doctor"
        description={
          <>
            Health-checks every installed service and repairs the ones that are unhealthy, which
            regenerates their configuration and recreates the containers. No data is deleted. This
            is the thing to run after an update.
          </>
        }
        action="doctor"
        icon={StethoscopeIcon}
        buttonLabel="Diagnose and repair"
        variant="outline"
        confirm="Health-check every service and repair whatever is unhealthy? Containers may restart. No data is deleted."
        output={outputs.doctor}
        running={running === "doctor"}
        onRun={onRun}
      />
    </div>
  )
}
