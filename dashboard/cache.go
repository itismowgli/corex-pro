package main

import (
	"sync"
	"time"
)

// A very small time-based cache, for the two shell-outs the dashboard makes
// most often and can least afford.
//
// Opening the page fires /api/services and /api/overview at once, and both
// used to run `corex manage status --plain` (0.7s measured) and
// `docker stats --no-stream`, which costs a full sampling interval by design
// (2.1s measured). The same two commands therefore ran twice per load, in
// series, before anything appeared.
//
// The window is deliberately shorter than the poll interval of anything that
// reads it, so nothing is ever served a value from a previous poll: it
// collapses the duplicate work inside one page load and does nothing else. A
// longer TTL would start hiding real state changes, which for a panel whose
// job is to say what the box is doing right now is the wrong trade.
type ttlCache struct {
	mu   sync.Mutex
	at   time.Time
	val  interface{}
	busy bool
	wait chan struct{}
}

// get returns the cached value if it is younger than ttl, and otherwise calls
// fn once. Concurrent callers arriving during a miss wait for that one call
// rather than each starting their own, which is the case that matters here:
// two handlers hitting a 2 second command at the same instant.
func (c *ttlCache) get(ttl time.Duration, fn func() interface{}) interface{} {
	for {
		c.mu.Lock()
		if c.val != nil && time.Since(c.at) < ttl {
			v := c.val
			c.mu.Unlock()
			return v
		}
		if c.busy {
			wait := c.wait
			c.mu.Unlock()
			<-wait
			continue
		}
		c.busy = true
		c.wait = make(chan struct{})
		wait := c.wait
		c.mu.Unlock()

		v := fn()

		c.mu.Lock()
		c.val, c.at, c.busy = v, time.Now(), false
		c.mu.Unlock()
		close(wait)
		return v
	}
}

var (
	moduleStatusCache ttlCache
	dockerStatsCache  ttlCache
)

// Shorter than the 15s the services list polls at, so a status badge is never
// older than the poll that asked for it.
const moduleStatusTTL = 5 * time.Second

// Container CPU/memory sampling is much more expensive than host vitals:
// `docker stats --no-stream` waits for a sampling interval and used to consume
// about a quarter of one core when run every five seconds. Temperature, load
// and host memory remain live at five seconds; container rankings refresh at
// this slower cadence, which is enough to spot sustained consumers.
const dockerStatsTTL = 30 * time.Second
