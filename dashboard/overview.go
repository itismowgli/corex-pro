package main

// The box at a glance.
//
// Everything here is data, not terminal output. The rest of the dashboard
// deliberately shows a command's own output, because those commands are the
// source of truth and a paraphrase is a second place to be wrong. That
// argument does not hold for numbers: a temperature, a disk percentage and a
// two-hour trend are not prose, and rendering them as a wall of monospace
// means reading a report rather than seeing the state of the machine.
//
// The host-side figures come from the agent's `metrics` action, because this
// container sees its own filesystem rather than the host's, so `df` in here
// measures the wrong thing entirely. Per-container CPU and memory come
// straight from the Docker socket, which this container already has.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ── Per container, from `docker stats` ────────────────────────────────────────

type containerRow struct {
	Name string `json:"name"`
	// The service module it belongs to, from the compose project label, so the
	// page can group eight containers under the three modules that own them.
	Service    string  `json:"service"`
	Status     string  `json:"status"`
	Health     string  `json:"health"`
	CPUPercent float64 `json:"cpu_percent"`
	MemBytes   int64   `json:"mem_bytes"`
	MemLimit   int64   `json:"mem_limit"`
	MemPercent float64 `json:"mem_percent"`
	Restarts   int     `json:"restarts"`
	OOMKilled  bool    `json:"oom_killed"`
	Since      string  `json:"since"`
}

// dockerStats reads live CPU and memory for running containers.
//
// One `docker stats --no-stream` call, not one per container: it takes a full
// sampling interval per invocation, so asking sixteen times is sixteen times
// the wait for the same answer.
// dockerStats is cached for a moment: `docker stats --no-stream` costs a full
// sampling interval by design, and the overview handler and the streaming
// sampler both want it.
func dockerStats() map[string]containerRow {
	return dockerStatsCache.get(dockerStatsTTL, func() interface{} {
		return dockerStatsUncached()
	}).(map[string]containerRow)
}

func dockerStatsUncached() map[string]containerRow {
	out := map[string]containerRow{}
	text, err := runCmd("docker", "stats", "--no-stream", "--format",
		"{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}")
	if err != nil {
		return out
	}
	for _, line := range strings.Split(text, "\n") {
		f := strings.Split(strings.TrimSpace(line), "\t")
		if len(f) < 4 {
			continue
		}
		used, limit := splitMemUsage(f[2])
		out[f[0]] = containerRow{
			Name:       f[0],
			CPUPercent: parsePercent(f[1]),
			MemBytes:   used,
			MemLimit:   limit,
			MemPercent: parsePercent(f[3]),
		}
	}
	return out
}

func parsePercent(s string) float64 {
	v, err := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(s), "%"), 64)
	if err != nil {
		return 0
	}
	return v
}

// splitMemUsage parses `docker stats` MemUsage, which is "1.01GiB / 3GiB".
func splitMemUsage(s string) (int64, int64) {
	parts := strings.SplitN(s, "/", 2)
	if len(parts) != 2 {
		return 0, 0
	}
	return parseSize(parts[0]), parseSize(parts[1])
}

var sizeUnits = map[string]float64{
	"b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
	"kib": 1024, "mib": 1024 * 1024, "gib": 1024 * 1024 * 1024,
	"tib": 1024 * 1024 * 1024 * 1024,
}

func parseSize(s string) int64 {
	s = strings.TrimSpace(s)
	i := 0
	for i < len(s) && (s[i] == '.' || (s[i] >= '0' && s[i] <= '9')) {
		i++
	}
	if i == 0 {
		return 0
	}
	n, err := strconv.ParseFloat(s[:i], 64)
	if err != nil {
		return 0
	}
	unit := strings.ToLower(strings.TrimSpace(s[i:]))
	mult, ok := sizeUnits[unit]
	if !ok {
		mult = 1
	}
	return int64(n * mult)
}

// containersHandler answers "who is consuming what, and who is misbehaving".
//
// Restart count and OOM kills are included because they are the two faults an
// HTTP check cannot see: a container that crash-loops is `Up 12 seconds` on
// almost every look, which reads as healthy (gotcha #29).
func containersHandler(w http.ResponseWriter, r *http.Request) {
	stats := dockerStats()

	text, err := runCmd("docker", "ps", "-a", "--format",
		"{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label \"com.docker.compose.project\"}}")
	if err != nil {
		writeErr(w, http.StatusInternalServerError,
			"cannot read the container list: "+err.Error())
		return
	}

	rows := []containerRow{}
	for _, line := range strings.Split(text, "\n") {
		f := strings.Split(strings.TrimSpace(line), "\t")
		if len(f) < 3 || f[0] == "" {
			continue
		}
		row := stats[f[0]]
		row.Name = f[0]
		row.Status = f[1]
		row.Since = f[2]
		if len(f) > 3 {
			row.Service = f[3]
		}
		rows = append(rows, row)
	}

	// Health, restarts and OOM in one inspect rather than one per container.
	if len(rows) > 0 {
		names := make([]string, 0, len(rows))
		for _, r := range rows {
			names = append(names, r.Name)
		}
		args := append([]string{"docker", "inspect", "--format",
			"{{.Name}}\t{{.RestartCount}}\t{{.State.OOMKilled}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}"},
			names...)
		if text, err := runCmd(args...); err == nil {
			meta := map[string][3]string{}
			for _, line := range strings.Split(text, "\n") {
				f := strings.Split(strings.TrimSpace(line), "\t")
				if len(f) < 4 {
					continue
				}
				meta[strings.TrimPrefix(f[0], "/")] = [3]string{f[1], f[2], f[3]}
			}
			for i := range rows {
				m, ok := meta[rows[i].Name]
				if !ok {
					continue
				}
				rows[i].Restarts, _ = strconv.Atoi(m[0])
				rows[i].OOMKilled = m[1] == "true"
				// Docker keeps the last health verdict on a stopped container
				// forever, so it is only meaningful while it is running.
				// Reading it unconditionally reported ten deliberately stopped
				// containers as unhealthy (gotcha #29).
				if rows[i].Status == "running" && m[2] != "-" {
					rows[i].Health = m[2]
				}
			}
		}
	}

	sort.Slice(rows, func(i, j int) bool {
		if rows[i].CPUPercent != rows[j].CPUPercent {
			return rows[i].CPUPercent > rows[j].CPUPercent
		}
		return rows[i].Name < rows[j].Name
	})
	writeJSON(w, http.StatusOK, rows)
}

// ── The overview payload ──────────────────────────────────────────────────────

type overview struct {
	// Straight from the agent, kept as raw JSON so a new field on that side
	// reaches the page without a matching struct here. The page is the only
	// consumer and it reads what it needs.
	Metrics json.RawMessage `json:"metrics"`

	Services struct {
		Healthy   int `json:"healthy"`
		Unhealthy int `json:"unhealthy"`
		Stopped   int `json:"stopped"`
		Missing   int `json:"missing"`
	} `json:"services"`

	Containers struct {
		Running    int `json:"running"`
		Total      int `json:"total"`
		Restarting int `json:"restarting"`
		Unhealthy  int `json:"unhealthy"`
	} `json:"containers"`

	Top       []containerRow `json:"top"`
	AgentOK   bool           `json:"agent_ok"`
	AgentErr  string         `json:"agent_error"`
	Collected string         `json:"collected_at"`
}

func overviewHandler(w http.ResponseWriter, r *http.Request) {
	var out overview
	out.Collected = time.Now().Format(time.RFC3339)
	out.AgentOK, out.AgentErr = agentReachable()

	// The three slow reads below do not depend on one another, and run in
	// series they were most of the wait before this page showed anything: the
	// agent's metrics (about a second, more on a cold `du`), the module status
	// inside getServices (0.7s), and `docker stats`, which costs a full
	// sampling interval by design (2.1s). Together the handler costs the
	// slowest of the three rather than their sum.
	var wg sync.WaitGroup
	var mu sync.Mutex
	var services []ServiceInfo
	var stats map[string]containerRow

	if out.AgentOK {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Sixty seconds: `du` is cached on the agent's side, but a cold
			// cache still has to walk a photo library once.
			res, err := agentCall(map[string]interface{}{
				"action": "metrics", "sizes": true,
			}, 60*time.Second)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				out.AgentOK = false
				out.AgentErr = err.Error()
			} else if !agentOK(res) {
				out.AgentErr = agentString(res, "error")
			} else if raw, err := json.Marshal(res["metrics"]); err == nil {
				out.Metrics = raw
			}
		}()
	}

	wg.Add(2)
	go func() {
		defer wg.Done()
		s := getServices(loadState())
		mu.Lock()
		services = s
		mu.Unlock()
	}()
	go func() {
		defer wg.Done()
		d := dockerStats()
		mu.Lock()
		stats = d
		mu.Unlock()
	}()
	wg.Wait()

	for _, s := range services {
		switch s.Status {
		case "HEALTHY":
			out.Services.Healthy++
		case "UNHEALTHY":
			out.Services.Unhealthy++
		case "MISSING":
			out.Services.Missing++
		default:
			out.Services.Stopped++
		}
	}

	if text, err := runCmd("docker", "ps", "-a", "--format",
		"{{.Names}}\t{{.State}}"); err == nil {
		for _, line := range strings.Split(text, "\n") {
			f := strings.Split(strings.TrimSpace(line), "\t")
			if len(f) < 2 || f[0] == "" {
				continue
			}
			out.Containers.Total++
			switch f[1] {
			case "running":
				out.Containers.Running++
			case "restarting":
				out.Containers.Restarting++
			}
		}
	}

	rows := make([]containerRow, 0, len(stats))
	for _, r := range stats {
		rows = append(rows, r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].CPUPercent != rows[j].CPUPercent {
			return rows[i].CPUPercent > rows[j].CPUPercent
		}
		return rows[i].MemBytes > rows[j].MemBytes
	})
	if len(rows) > 8 {
		rows = rows[:8]
	}
	out.Top = rows

	writeJSON(w, http.StatusOK, out)
}

// humanBytes is used by the log formatter's summaries. Kept here beside the
// parser so the two stay in step.
func humanBytes(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "kMGTPE"[exp])
}

// ── Live vitals ───────────────────────────────────────────────────────────────

// vitals is the small, cheap half of the overview: the numbers that change
// every few seconds. Kept apart from the full payload on purpose, because that
// one walks both disks, reads Kuma's database and may wait on a `du`, none of
// which is worth doing three times a minute.
type vitals struct {
	At         int64          `json:"at"`
	TempC      *float64       `json:"temp_c"`
	TempState  string         `json:"temp_state"`
	Load       []float64      `json:"load"`
	Cores      int            `json:"cores"`
	MemUsedMB  int            `json:"mem_used_mb"`
	MemTotalMB int            `json:"mem_total_mb"`
	SwapUsedMB int            `json:"swap_used_mb"`
	Running    int            `json:"containers_running"`
	Total      int            `json:"containers_total"`
	Restarting int            `json:"containers_restarting"`
	Top        []containerRow `json:"top"`
	AgentOK    bool           `json:"agent_ok"`
}

func collectVitals() vitals {
	v := vitals{At: time.Now().Unix()}
	v.AgentOK, _ = agentReachable()

	if v.AgentOK {
		// sizes:false, so the agent skips the cached `du` entirely. This call
		// runs every few seconds and must stay cheap.
		if res, err := agentCall(map[string]interface{}{
			"action": "metrics", "sizes": false,
		}, 15*time.Second); err == nil && agentOK(res) {
			raw, _ := json.Marshal(res["metrics"])
			var m struct {
				CPU struct {
					TempC     *float64  `json:"temp_c"`
					TempState string    `json:"temp_state"`
					Load      []float64 `json:"load"`
					Cores     int       `json:"cores"`
				} `json:"cpu"`
				Memory struct {
					UsedMB  int `json:"used_mb"`
					TotalMB int `json:"total_mb"`
					SwapMB  int `json:"swap_used_mb"`
				} `json:"memory"`
			}
			if json.Unmarshal(raw, &m) == nil {
				v.TempC, v.TempState = m.CPU.TempC, m.CPU.TempState
				v.Load, v.Cores = m.CPU.Load, m.CPU.Cores
				v.MemUsedMB, v.MemTotalMB = m.Memory.UsedMB, m.Memory.TotalMB
				v.SwapUsedMB = m.Memory.SwapMB
			}
		}
	}

	stats := dockerStats()
	if text, err := runCmd("docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}"); err == nil {
		for _, line := range strings.Split(text, "\n") {
			f := strings.Split(strings.TrimSpace(line), "\t")
			if len(f) < 2 || f[0] == "" {
				continue
			}
			v.Total++
			switch f[1] {
			case "running":
				v.Running++
			case "restarting":
				v.Restarting++
			}
		}
	}
	rows := make([]containerRow, 0, len(stats))
	for _, r := range stats {
		rows = append(rows, r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].CPUPercent != rows[j].CPUPercent {
			return rows[i].CPUPercent > rows[j].CPUPercent
		}
		return rows[i].MemBytes > rows[j].MemBytes
	})
	if len(rows) > 8 {
		rows = rows[:8]
	}
	v.Top = rows
	return v
}

// vitalsStreamHandler pushes vitals over Server-Sent Events.
//
// Polling was showing numbers that were up to twenty seconds old, which for a
// temperature on hardware that trips at TjMax is the wrong kind of stale. SSE
// rather than a websocket because the traffic is one way, it survives the
// reverse proxy without an upgrade negotiation, and the browser reconnects on
// its own. The log stream already works this way.
//
// `docker stats --no-stream` costs a full sampling interval, so five seconds
// is about the floor before this spends more time measuring than waiting.
// One sampler for every viewer, and none when there are no viewers.
//
// The stream used to sample per connection. collectVitals runs
// `docker stats --no-stream`, which costs a full sampling interval: measured
// at 1.16 seconds on this box. At a five second tick that is a quarter of a
// core for one open tab, half for two, and most of a core for three, running
// for as long as a tab is left open, on hardware that thermal-trips. The
// dashboard was one of the hottest things on the box purely to draw itself.
//
// So subscribers share one loop. It starts when the first one arrives, stops
// when the last one leaves, and a new subscriber is handed the most recent
// sample straight away rather than waiting up to five seconds for the next
// tick or triggering a sample of its own.
var vitalsHub = struct {
	sync.Mutex
	subs    map[chan []byte]struct{}
	running bool
	last    []byte
	lastAt  time.Time
}{subs: map[chan []byte]struct{}{}}

const vitalsInterval = 5 * time.Second

// vitalsSubscribe returns a channel of encoded samples, the freshest sample
// already taken if there is one, and a function to unsubscribe.
func vitalsSubscribe() (<-chan []byte, []byte, func()) {
	ch := make(chan []byte, 1)
	vitalsHub.Lock()
	vitalsHub.subs[ch] = struct{}{}
	var seed []byte
	// A sample older than one interval is not worth showing as current; the
	// loop is about to produce a new one anyway.
	if time.Since(vitalsHub.lastAt) < vitalsInterval {
		seed = vitalsHub.last
	}
	start := !vitalsHub.running
	if start {
		vitalsHub.running = true
	}
	vitalsHub.Unlock()

	if start {
		go vitalsLoop()
	}
	return ch, seed, func() {
		vitalsHub.Lock()
		delete(vitalsHub.subs, ch)
		vitalsHub.Unlock()
	}
}

func vitalsLoop() {
	for {
		body, err := json.Marshal(collectVitals())
		vitalsHub.Lock()
		if err == nil {
			vitalsHub.last, vitalsHub.lastAt = body, time.Now()
		}
		if len(vitalsHub.subs) == 0 {
			vitalsHub.running = false
			vitalsHub.Unlock()
			return
		}
		if err == nil {
			for ch := range vitalsHub.subs {
				// Never block on a subscriber. A client that has stopped
				// reading must not hold up the sampler for everyone else, and
				// a dropped sample is replaced five seconds later.
				select {
				case ch <- body:
				default:
				}
			}
		}
		vitalsHub.Unlock()
		time.Sleep(vitalsInterval)
	}
}

func vitalsStreamHandler(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "streaming is not supported here")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// Without this an intermediate proxy buffers the stream and nothing
	// arrives until it closes, which looks exactly like a hung page.
	w.Header().Set("X-Accel-Buffering", "no")

	ch, seed, unsubscribe := vitalsSubscribe()
	defer unsubscribe()

	send := func(body []byte) bool {
		if _, err := fmt.Fprintf(w, "data: %s\n\n", body); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	if seed != nil && !send(seed) {
		return
	}

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case body := <-ch:
			if !send(body) {
				return
			}
		}
	}
}
