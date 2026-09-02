package main

import (
	"bufio"
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"
)

//go:embed templates static
var assets embed.FS

// ── Data types ────────────────────────────────────────────────────────────────

type CoreXState struct {
	Version  string                  `json:"version"`
	Domain   string                  `json:"domain"`
	ServerIP string                  `json:"server_ip"`
	SSHPort  string                  `json:"ssh_port"`
	Timezone string                  `json:"timezone"`
	Services map[string]ServiceEntry `json:"services"`

	// n8n's hostname is overridable, because a name can be blocked by
	// something outside the service: Google Safe Browsing flagged
	// n8n.DOMAIN while n8n itself kept returning HTTP 200. Empty means the
	// default, "n8n".
	N8nSubdomain string `json:"n8n_subdomain"`
}

type ServiceEntry struct {
	Installed bool `json:"installed"`
	Enabled   bool `json:"enabled"`
}

type ServiceInfo struct {
	Name      string
	Label     string
	Status    string // HEALTHY | UNHEALTHY | MISSING
	URLs      []string
	Container string
}

type PageData struct {
	State   CoreXState
	Tab     string
	Content template.HTML
}

// ── Service metadata ──────────────────────────────────────────────────────────

// Display name per service module. Keys must be module names, that is the
// filenames in lib/services/. "uptime-kuma" was a key here and in two other
// maps but is not a module: Uptime Kuma ships inside the monitoring module,
// so that entry never matched anything.
var serviceLabels = map[string]string{
	"adguard":     "AdGuard Home — DNS & Ad Blocker",
	"ai":          "AI Stack — Ollama + WebUI",
	"cloudflared": "Cloudflare Tunnel — External Access",
	"coolify":     "Coolify — App Platform",
	"crowdsec":    "CrowdSec — Intrusion Prevention",
	"dashboard":   "CoreX Dashboard",
	"immich":      "Immich — Photo Library",
	"monitoring":  "Monitoring — Uptime Kuma + Grafana + Prometheus",
	"n8n":         "n8n — Workflow Automation",
	"nextcloud":   "Nextcloud — File Storage",
	"portainer":   "Portainer — Container Manager",
	"stalwart":    "Stalwart — Mail Server",
	"timemachine": "Time Machine — Mac Backup",
	"traefik":     "Traefik — Reverse Proxy",
	"ups":         "UPS — Power Monitoring",
	"vaultwarden": "Vaultwarden — Password Manager",
}

// serviceURLs lists the addresses each service module actually answers on.
// {DOMAIN} and {IP} are substituted from state.json.
//
// These must match the Traefik Host rules in lib/services/*.sh, whether
// declared as a Docker label or written into Traefik's file-provider
// directory. A Host rule is the only thing that makes a hostname resolvable. Guessing "<service>.DOMAIN"
// produced four dead links: immich answers on photos, not immich; adguard has
// no Traefik router and is reached on its own port; the Traefik dashboard is
// bound to loopback; and coolify installs its own stack on port 8000. The
// "uptime-kuma" key was never a module name either, so status.DOMAIN was
// missing from the dashboard entirely.
//
// A module can serve more than one address: monitoring answers on both
// grafana and status.
var serviceURLs = map[string][]string{
	"adguard": {"http://{IP}:3000"},
	"ai":      {"https://ai.{DOMAIN}"},
	// Routed by a Traefik file-provider rule rather than a Docker label,
	// because Coolify sits on its own network. Port 8000 stays listed as the
	// LAN way in and the address the route itself connects to.
	"coolify":     {"https://coolify.{DOMAIN}", "http://{IP}:8000"},
	"dashboard":   {"https://dashboard.{DOMAIN}"},
	"immich":      {"https://photos.{DOMAIN}"},
	"monitoring":  {"https://grafana.{DOMAIN}", "https://status.{DOMAIN}"},
	"n8n":         {"https://n8n.{DOMAIN}"},
	"nextcloud":   {"https://nextcloud.{DOMAIN}"},
	"portainer":   {"https://portainer.{DOMAIN}"},
	"stalwart":    {"https://mail.{DOMAIN}"},
	"timemachine": {"smb://{IP}/CoreX_Backup"},
	"vaultwarden": {"https://vault.{DOMAIN}"},
	// crowdsec, ups and traefik have no browsable address. Traefik's dashboard
	// is published on 127.0.0.1:8080 and needs an SSH tunnel.
}

// Primary container name per service (used for status check and log streaming)
// Representative container per service module, used for the log stream and as
// the health fallback when the service modules cannot be consulted. A module
// may run several containers; this names the one worth tailing.
//
// ups has no entry on purpose: NUT runs on the host, not in Docker.
var serviceContainers = map[string]string{
	"adguard":     "adguard",
	"ai":          "ollama",
	"cloudflared": "cloudflared",
	"coolify":     "coolify",
	"crowdsec":    "crowdsec",
	"dashboard":   "corex-dashboard",
	"immich":      "immich-server",
	"monitoring":  "grafana",
	"n8n":         "n8n",
	"nextcloud":   "nextcloud",
	"portainer":   "portainer",
	"stalwart":    "stalwart",
	"timemachine": "timemachine",
	"traefik":     "traefik",
	"vaultwarden": "vaultwarden",
}

// ── Globals ───────────────────────────────────────────────────────────────────

var (
	tmpl   *template.Template
	manage string
)

// ── Entry point ───────────────────────────────────────────────────────────────

func main() {
	manage = getenv("COREX_MANAGE", "/opt/corex-pro/corex-manage.sh")

	var err error
	tmpl, err = template.New("").ParseFS(assets, "templates/*.html")
	if err != nil {
		log.Fatalf("parse templates: %v", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/static/", http.FileServer(http.FS(assets)))
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/tab/", tabHandler)
	mux.HandleFunc("/api/service/", serviceActionHandler)
	mux.HandleFunc("/api/cleanup", cleanupHandler)
	mux.HandleFunc("/api/job/", jobHandler)
	mux.HandleFunc("/api/logs/", logsSSEHandler)

	log.Printf("CoreX Dashboard listening on :8080 (domain=%s)", getenv("DOMAIN", "unconfigured"))
	log.Fatal(http.ListenAndServe(":8080", mux))
}

// ── State helpers ─────────────────────────────────────────────────────────────

func loadState() CoreXState {
	var s CoreXState
	data, err := os.ReadFile("/etc/corex/state.json")
	if err != nil {
		// Silence here is how the dashboard came to report "No services
		// installed" on a box running 36 containers: state.json was mode
		// 0600 root, the container runs as nobody, and the read error was
		// discarded. An unreadable state file is a deployment fault and has
		// to say so.
		log.Printf("loadState: cannot read /etc/corex/state.json: %v", err)
	} else if err := json.Unmarshal(data, &s); err != nil {
		log.Printf("loadState: cannot parse /etc/corex/state.json: %v", err)
	}
	if s.Domain == "" {
		s.Domain = getenv("DOMAIN", "")
	}
	// state.json can hold a domain with embedded quotes, from a v1 migration
	// regex that captured the quotes around the YAML field. Left in place it
	// produces URLs like https://adguard."example.com", so every link on the
	// page is broken.
	s.Domain = strings.Trim(s.Domain, "\"'")
	s.ServerIP = strings.Trim(s.ServerIP, "\"'")
	if s.ServerIP == "" {
		s.ServerIP = getenv("SERVER_IP", "")
	}
	return s
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// ── Action agent client ───────────────────────────────────────────────────────
//
// The buttons used to shell out to corex-manage.sh directly, which could never
// work: this container runs as nobody and corex-manage requires root, so every
// action returned "Run as root". Rather than make the web container root or
// give it sudo, a single privileged agent on the host exposes a fixed list of
// reversible actions over a unix socket. The container reaches it by being a
// member of the corex-agent group; see lib/agent.sh.

var (
	agentSocket    = getenv("COREX_AGENT_SOCKET", "/run/corex/agent.sock")
	agentTokenFile = getenv("COREX_AGENT_TOKEN_FILE", "/etc/corex/agent.token")
)

// jobIDRe guards the job id before it is interpolated into a polling URL and
// an element id. The agent generates hex, so anything else is not ours.
var jobIDRe = regexp.MustCompile(`^[a-f0-9]{6,32}$`)

func agentCall(req map[string]interface{}, timeout time.Duration) (map[string]interface{}, error) {
	token, err := os.ReadFile(agentTokenFile)
	if err != nil {
		return nil, fmt.Errorf("cannot read the agent token: %w", err)
	}
	req["token"] = strings.TrimSpace(string(token))

	conn, err := net.DialTimeout("unix", agentSocket, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("agent unreachable: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	if _, err := conn.Write(append(body, '\n')); err != nil {
		return nil, fmt.Errorf("agent write failed: %w", err)
	}

	// The reply is one line. Cap it so a misbehaving agent cannot exhaust the
	// 128MB this container is limited to.
	rd := bufio.NewReaderSize(conn, 64*1024)
	line, err := rd.ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return nil, fmt.Errorf("agent read failed: %w", err)
	}
	var out map[string]interface{}
	if err := json.Unmarshal(line, &out); err != nil {
		return nil, fmt.Errorf("malformed agent reply: %w", err)
	}
	return out, nil
}

func agentString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func agentOK(m map[string]interface{}) bool {
	ok, _ := m["ok"].(bool)
	return ok
}

// ── Job rendering ─────────────────────────────────────────────────────────────

func writeFragment(w http.ResponseWriter, html string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, html)
}

func errorFragment(w http.ResponseWriter, msg string) {
	writeFragment(w, fmt.Sprintf(
		`<pre class="rounded p-3 text-xs bg-gray-950 text-red-400 overflow-auto max-h-48 font-mono whitespace-pre-wrap">%s</pre>`,
		template.HTMLEscapeString(msg)))
}

// runningFragment polls itself until the job finishes. Actions are asynchronous
// because update and repair outlast any sensible request timeout, and a button
// that appears to hang is how you end up clicking it twice.
func runningFragment(w http.ResponseWriter, jobID, label string) {
	writeFragment(w, fmt.Sprintf(
		`<div id="job-%s" hx-get="/api/job/%s" hx-trigger="load delay:2s" hx-swap="outerHTML">`+
			`<pre class="rounded p-3 text-xs bg-gray-950 text-blue-300 font-mono whitespace-pre-wrap">`+
			`$ %s&#10;<span class="text-gray-500">running, this updates on its own…</span></pre></div>`,
		template.HTMLEscapeString(jobID),
		template.HTMLEscapeString(jobID),
		template.HTMLEscapeString(label),
	))
}

func finishedFragment(w http.ResponseWriter, jobID, label, output string, ok bool) {
	colour := "text-green-400"
	status := "done"
	if !ok {
		colour = "text-red-400"
		status = "failed"
	}
	if strings.TrimSpace(output) == "" {
		output = "(no output)"
	}
	// No hx-trigger, so this is the last swap and the polling stops.
	//
	// It deliberately does not refresh the tab by itself. The tab links are
	// full page loads into #content, so an automatic refresh would replace
	// this element with the service grid a second after it appeared, throwing
	// away the output the user is reading. The badges are stale until they ask.
	writeFragment(w, fmt.Sprintf(
		`<div id="job-%s">`+
			`<pre class="rounded p-3 text-xs bg-gray-950 %s overflow-auto max-h-64 font-mono whitespace-pre-wrap">`+
			`$ %s&#10;%s&#10;<span class="text-gray-500">%s</span></pre>`+
			`<button hx-get="/tab/services" hx-target="#content" hx-swap="innerHTML" `+
			`class="mt-2 px-2.5 py-1 text-xs rounded bg-gray-800 hover:bg-gray-700 text-gray-300 hover:text-white transition-colors">`+
			`Refresh statuses</button></div>`,
		template.HTMLEscapeString(jobID), colour,
		template.HTMLEscapeString(label),
		template.HTMLEscapeString(output),
		status,
	))
}

// jobHandler serves GET /api/job/<id>, the polling endpoint for a running job.
func jobHandler(w http.ResponseWriter, r *http.Request) {
	jobID := strings.TrimPrefix(r.URL.Path, "/api/job/")
	if !jobIDRe.MatchString(jobID) {
		errorFragment(w, "bad job id")
		return
	}
	res, err := agentCall(map[string]interface{}{"action": "job", "job_id": jobID}, 30*time.Second)
	if err != nil {
		errorFragment(w, err.Error())
		return
	}
	if !agentOK(res) {
		errorFragment(w, agentString(res, "error"))
		return
	}
	label := strings.TrimSpace(agentString(res, "action") + " " + agentString(res, "service"))
	switch agentString(res, "state") {
	case "running":
		runningFragment(w, jobID, label)
	case "done":
		finishedFragment(w, jobID, label, agentString(res, "output"), true)
	default:
		finishedFragment(w, jobID, label, agentString(res, "output"), false)
	}
}

// ── Command helpers ───────────────────────────────────────────────────────────

func runCmd(args ...string) (string, error) {
	cmd := exec.Command(args[0], args[1:]...) //nolint:gosec
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func runManage(args ...string) (string, error) {
	return runCmd(append([]string{"bash", manage}, args...)...)
}

func getRunningContainers() map[string]bool {
	out, err := runCmd("docker", "ps", "--format", "{{.Names}}")
	result := map[string]bool{}
	if err != nil {
		// Without socket access every service looks stopped. Say so once in
		// the log rather than reporting 15 healthy services as unhealthy.
		log.Printf("cannot query Docker (%v): %s", err, out)
		return result
	}
	for _, line := range strings.Split(out, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			result[line] = true
		}
	}
	return result
}

func containerExists(name string) bool {
	out, err := runCmd("docker", "ps", "-a", "--filter", "name=^/"+name+"$", "--format", "{{.Names}}")
	if err != nil {
		return false
	}
	// Match the name rather than accepting any output. runCmd merges stderr,
	// so a Docker socket permission error would otherwise read as "exists".
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == name {
			return true
		}
	}
	return false
}

// ── Services ──────────────────────────────────────────────────────────────────

func getServices(state CoreXState) []ServiceInfo {
	running := getRunningContainers()
	var svcs []ServiceInfo

	// Health belongs to the service modules, which know more than "is the
	// container up". Stalwart is the clearest case: a bootstrap-mode server,
	// or one that has banned the proxy IP in front of it, is running and
	// completely unusable. Deriving health from docker ps alone made this
	// dashboard disagree with `corex doctor` and report such a service
	// HEALTHY. Fall back to the container check only if the modules cannot
	// be consulted.
	moduleStatus := map[string]string{}
	if out, err := runManage("status", "--plain"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			parts := strings.SplitN(strings.TrimSpace(line), "\t", 2)
			if len(parts) == 2 && parts[0] != "" {
				moduleStatus[parts[0]] = strings.TrimSpace(parts[1])
			}
		}
	} else {
		log.Printf("serviceList: module status unavailable, falling back to container state: %v", err)
	}

	for name, entry := range state.Services {
		if !entry.Installed {
			continue
		}
		container := serviceContainers[name]
		status := "MISSING"
		if container != "" {
			if running[container] {
				status = "HEALTHY"
			} else if containerExists(container) {
				status = "UNHEALTHY"
			}
		}
		if ms, ok := moduleStatus[name]; ok && ms != "" && ms != "UNKNOWN" {
			status = ms
		}

		var urls []string
		for _, tpl := range serviceURLs[name] {
			u := tpl
			if strings.Contains(u, "{DOMAIN}") {
				if state.Domain == "" {
					continue
				}
				u = strings.ReplaceAll(u, "{DOMAIN}", state.Domain)
			}
			if strings.Contains(u, "{IP}") {
				if state.ServerIP == "" {
					continue
				}
				u = strings.ReplaceAll(u, "{IP}", state.ServerIP)
			}
			urls = append(urls, u)
		}

		// Follow an overridden hostname, or the dashboard would keep linking
		// to the name the user moved away from.
		if name == "n8n" && state.N8nSubdomain != "" && state.Domain != "" {
			urls = []string{"https://" + strings.Trim(state.N8nSubdomain, "\"'") + "." + state.Domain}
		}

		label := serviceLabels[name]
		if label == "" {
			label = name
		}

		svcs = append(svcs, ServiceInfo{
			Name:      name,
			Label:     label,
			Status:    status,
			URLs:      urls,
			Container: container,
		})
	}

	sort.Slice(svcs, func(i, j int) bool { return svcs[i].Name < svcs[j].Name })
	return svcs
}

// ── System info ───────────────────────────────────────────────────────────────

func getSysInfo(state CoreXState) map[string]string {
	info := map[string]string{
		"domain":        state.Domain,
		"server_ip":     state.ServerIP,
		"corex_version": state.Version,
		"ssh_port":      state.SSHPort,
	}
	if info["ssh_port"] == "" || info["ssh_port"] == "null" {
		// Detect from running sshd when state is missing the field
		if p, err := runCmd("bash", "-c", "sshd -T 2>/dev/null | awk '/^port /{print $2;exit}'"); err == nil && p != "" {
			info["ssh_port"] = p
		} else {
			info["ssh_port"] = "22"
		}
	}
	hostname, _ := os.Hostname()
	info["hostname"] = hostname
	info["kernel"], _ = runCmd("uname", "-r")
	info["uptime"], _ = runCmd("uptime", "-p")
	info["docker"], _ = runCmd("docker", "version", "--format", "{{.Server.Version}}")
	return info
}

// ── Template rendering ────────────────────────────────────────────────────────

func renderTabContent(tab string, state CoreXState) (template.HTML, error) {
	var buf bytes.Buffer

	switch tab {
	case "services":
		err := tmpl.ExecuteTemplate(&buf, "services.html", struct {
			Services []ServiceInfo
			State    CoreXState
		}{getServices(state), state})
		if err != nil {
			return "", err
		}

	case "storage":
		out, err := runManage("storage")
		if err != nil {
			// Discarding this error is why the Storage tab silently showed
			// nothing for so long: corex-manage.sh refused to run as nobody
			// and the "Run as root" message went straight into the void.
			log.Printf("storage tab: corex-manage storage failed: %v (output: %q)", err, out)
		}
		if err = tmpl.ExecuteTemplate(&buf, "storage.html", struct {
			Output string
			State  CoreXState
		}{out, state}); err != nil {
			return "", err
		}

	case "network":
		err := tmpl.ExecuteTemplate(&buf, "network.html", struct {
			Services []ServiceInfo
			State    CoreXState
		}{getServices(state), state})
		if err != nil {
			return "", err
		}

	case "system":
		err := tmpl.ExecuteTemplate(&buf, "system.html", struct {
			Sys   map[string]string
			State CoreXState
		}{getSysInfo(state), state})
		if err != nil {
			return "", err
		}

	default:
		return "", fmt.Errorf("unknown tab: %s", tab)
	}

	return template.HTML(buf.String()), nil //nolint:gosec
}

func renderFull(w http.ResponseWriter, tab string) {
	state := loadState()
	content, err := renderTabContent(tab, state)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.ExecuteTemplate(w, "layout.html", PageData{
		State: state, Tab: tab, Content: content,
	}); err != nil {
		log.Printf("render layout: %v", err)
	}
}

func renderPartial(w http.ResponseWriter, tab string) {
	state := loadState()
	content, err := renderTabContent(tab, state)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, string(content))
}

// ── Route handlers ────────────────────────────────────────────────────────────

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Header.Get("HX-Boosted") == "true" {
		renderFull(w, "services")
	} else if r.Header.Get("HX-Request") == "true" {
		renderPartial(w, "services")
	} else {
		renderFull(w, "services")
	}
}

func tabHandler(w http.ResponseWriter, r *http.Request) {
	tab := strings.TrimPrefix(r.URL.Path, "/tab/")
	if tab == "" {
		tab = "services"
	}
	// hx-boost sends HX-Request + HX-Boosted — return full page so the nav re-renders
	if r.Header.Get("HX-Request") == "true" && r.Header.Get("HX-Boosted") == "" {
		renderPartial(w, tab)
	} else {
		renderFull(w, tab)
	}
}

// serviceActionHandler handles POST /api/service/<name>/<action>
func serviceActionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/api/service/"), "/", 2)
	if len(parts) != 2 {
		http.Error(w, "path must be /api/service/<name>/<action>", 400)
		return
	}
	svcName, action := parts[0], parts[1]

	// Validate inputs — only allow known service names and actions
	if _, ok := serviceLabels[svcName]; !ok {
		http.Error(w, "unknown service", 400)
		return
	}
	// Mirrors the agent's own whitelist. Anything destructive is absent from
	// both: remove, replace and migrate stay on SSH.
	actionLabel := map[string]string{
		"start":   "start",
		"stop":    "stop",
		"restart": "restart",
		"repair":  "repair",
		"update":  "update",
	}
	if _, ok := actionLabel[action]; !ok {
		http.Error(w, "unknown action", 400)
		return
	}

	res, err := agentCall(map[string]interface{}{
		"action":  action,
		"service": svcName,
	}, 60*time.Second)
	if err != nil {
		errorFragment(w, err.Error())
		return
	}
	if !agentOK(res) {
		errorFragment(w, agentString(res, "error"))
		return
	}

	label := action + " " + svcName
	if jobID := agentString(res, "job_id"); jobIDRe.MatchString(jobID) {
		runningFragment(w, jobID, label)
		return
	}
	// A synchronous action, which the agent answers inline.
	finishedFragment(w, "sync", label, agentString(res, "output"), true)
}

func cleanupHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	// The dry run is read-only and quick, so it stays inline. A real cleanup
	// prunes images and build cache and can run for minutes, so it becomes a
	// job like any other action.
	req := map[string]interface{}{"action": "cleanup"}
	if r.URL.Query().Get("dry_run") == "1" {
		out, err := runManage("cleanup", "--dry-run")
		colour := "text-green-400"
		if err != nil {
			colour = "text-yellow-400"
		}
		writeFragment(w, fmt.Sprintf(
			`<pre class="rounded p-3 text-xs bg-gray-950 %s overflow-auto max-h-64 font-mono whitespace-pre-wrap">%s</pre>`,
			colour, template.HTMLEscapeString(out)))
		return
	}

	res, err := agentCall(req, 60*time.Second)
	if err != nil {
		errorFragment(w, err.Error())
		return
	}
	if !agentOK(res) {
		errorFragment(w, agentString(res, "error"))
		return
	}
	if jobID := agentString(res, "job_id"); jobIDRe.MatchString(jobID) {
		runningFragment(w, jobID, "cleanup")
		return
	}
	finishedFragment(w, "sync", "cleanup", agentString(res, "output"), true)
}

// logsSSEHandler streams container logs as Server-Sent Events.
// The browser connects with EventSource; closing the tab cancels the subprocess.
func logsSSEHandler(w http.ResponseWriter, r *http.Request) {
	container := strings.TrimPrefix(r.URL.Path, "/api/logs/")
	if container == "" {
		http.Error(w, "container name required", 400)
		return
	}
	// Validate: only allow known container names
	known := false
	for _, c := range serviceContainers {
		if c == container {
			known = true
			break
		}
	}
	if !known {
		http.Error(w, "unknown container", 400)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, canFlush := w.(http.Flusher)
	ctx := r.Context()

	cmd := exec.CommandContext(ctx, "docker", "logs", "-f", "--tail", "100", container) //nolint:gosec
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Fprintf(w, "data: error: %v\n\n", err)
		return
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(w, "data: error starting: %v\n\n", err)
		return
	}

	scanner := bufio.NewScanner(pipe)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			_ = cmd.Process.Kill()
			return
		default:
		}
		fmt.Fprintf(w, "data: %s\n\n", template.HTMLEscapeString(scanner.Text()))
		if canFlush {
			flusher.Flush()
		}
	}
	_ = cmd.Wait()
	fmt.Fprintf(w, "data: [stream ended]\n\n")
	if canFlush {
		flusher.Flush()
	}
}
