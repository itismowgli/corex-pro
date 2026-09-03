package main

import (
	"bufio"
	"encoding/json"
	"embed"
	"fmt"
	"html/template"
	"io/fs"
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

// The built single-page app. Everything the browser needs is in here: no CDN
// for the stylesheet, none for the JavaScript, no font fetched at runtime.
//
// That is not tidiness. The previous version loaded Tailwind from
// cdn.tailwindcss.com and htmx from unpkg, so the dashboard needed the
// internet to render, which is the wrong dependency for the page you open when
// the box is in trouble. Worse, the htmx tag carried an integrity hash that
// did not match the file, so every browser refused to execute it and every
// button on the page silently did nothing.
//
// `all:` so that hashed asset names starting with an underscore are included.
// The build is `npm run build` inside web/, which the Dockerfile runs.
//
//go:embed all:web/dist
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

	// Same idea for Cal.com, whose booking links are shared with other
	// people and so are the worst thing to have to change.
	CalcomSubdomain string `json:"calcom_subdomain"`
}

type ServiceEntry struct {
	Installed bool `json:"installed"`
	Enabled   bool `json:"enabled"`
}

type ServiceInfo struct {
	Name      string   `json:"name"`
	Label     string   `json:"label"`
	Status    string   `json:"status"` // HEALTHY | UNHEALTHY | MISSING | DISABLED
	URLs      []string `json:"urls"`
	Container string   `json:"container"`
	Enabled   bool     `json:"enabled"`
}

// hostInfo is what the System tab shows, plus whether the buttons can work at
// all. The agent fields exist because "the action failed" and "no action can
// ever succeed here" need different answers, and the old dashboard could not
// tell them apart.
type hostInfo struct {
	Version    string `json:"version"`
	Domain     string `json:"domain"`
	ServerIP   string `json:"server_ip"`
	SSHPort    string `json:"ssh_port"`
	Hostname   string `json:"hostname"`
	Kernel     string `json:"kernel"`
	Uptime     string `json:"uptime"`
	Docker     string `json:"docker"`
	Timezone   string `json:"timezone"`
	AgentOK    bool   `json:"agent_ok"`
	AgentError string `json:"agent_error"`
}

type jobView struct {
	ID     string `json:"id"`
	State  string `json:"state"` // running | done | failed
	Label  string `json:"label"`
	Output string `json:"output"`
}

type portRow struct {
	Service string `json:"service"`
	URL     string `json:"url"`
	Note    string `json:"note"`
}

// ── Service metadata ──────────────────────────────────────────────────────────

// Display name per service module. Keys must be module names, that is the
// filenames in lib/services/. "uptime-kuma" was a key here and in two other
// maps but is not a module: Uptime Kuma ships inside the monitoring module,
// so that entry never matched anything.
var serviceLabels = map[string]string{
	"adguard":     "AdGuard Home — DNS & Ad Blocker",
	"ai":          "AI Stack — Ollama + WebUI",
	"calcom":      "Cal.com — Scheduling & Booking",
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
	"calcom":  {"https://cal.{DOMAIN}"},
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
	"calcom":      "calcom",
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

var manage = getenv("COREX_MANAGE", "/opt/corex-pro/corex-manage.sh")

// ── Entry point ───────────────────────────────────────────────────────────────

func main() {
	dist, err := fs.Sub(assets, "web/dist")
	if err != nil {
		log.Fatalf("embedded assets are unusable: %v", err)
	}
	if _, err := fs.Stat(dist, "index.html"); err != nil {
		// Compiling without building the frontend first produces a binary
		// that serves nothing, and a blank page is the least diagnosable
		// failure there is. Say it once at startup and again in the response.
		log.Printf("WARNING: web/dist/index.html is missing from the binary. "+
			"Run `npm ci && npm run build` in dashboard/web before `go build` (%v)", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/state", stateHandler)
	mux.HandleFunc("/api/services", servicesHandler)
	mux.HandleFunc("/api/storage", storageHandler)
	mux.HandleFunc("/api/ports", portsHandler)
	mux.HandleFunc("/api/service/", serviceActionHandler)
	mux.HandleFunc("/api/cleanup", cleanupHandler)
	mux.HandleFunc("/api/job/", jobHandler)
	mux.HandleFunc("/api/logs/", logsSSEHandler)
	mux.Handle("/", spaHandler(dist))

	log.Printf("CoreX Dashboard listening on :8080 (manage=%s, agent=%s)", manage, agentSocket)
	srv := &http.Server{
		Addr:    ":8080",
		Handler: mux,
		// No WriteTimeout on purpose: /api/logs/ is an open-ended SSE stream
		// and a write deadline would cut it off mid-session.
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

// spaHandler serves the built assets, falling back to index.html so a deep
// link such as /#system still loads the app rather than 404ing.
func spaHandler(dist fs.FS) http.Handler {
	files := http.FileServer(http.FS(dist))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/")
		if name == "" {
			name = "index.html"
		}
		if _, err := fs.Stat(dist, name); err != nil {
			if _, err := fs.Stat(dist, "index.html"); err != nil {
				http.Error(w,
					"The dashboard assets were not built into this binary.\n"+
						"Build them with: cd dashboard/web && npm ci && npm run build\n",
					http.StatusInternalServerError)
				return
			}
			r = r.Clone(r.Context())
			r.URL.Path = "/"
		}
		// Hashed asset names are immutable; index.html must not be, or a
		// deploy leaves browsers on the previous app.
		if strings.HasPrefix(name, "assets/") {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			w.Header().Set("Cache-Control", "no-cache")
		}
		files.ServeHTTP(w, r)
	})
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

// ── JSON plumbing ─────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writeJSON: %v", err)
	}
}

// Errors reach the browser as JSON with the same shape, so the client has one
// path for reporting them instead of guessing at HTML.
func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// agentReachable answers "can the buttons work", which is a different question
// from "did this action succeed". It dials and closes: no action is sent, so
// this is safe to call on every poll. The token has to be readable too, since
// the agent rejects a request without one.
func agentReachable() (bool, string) {
	if _, err := os.ReadFile(agentTokenFile); err != nil {
		return false, fmt.Sprintf("cannot read %s: %v", agentTokenFile, err)
	}
	conn, err := net.DialTimeout("unix", agentSocket, 2*time.Second)
	if err != nil {
		return false, fmt.Sprintf("cannot reach %s: %v", agentSocket, err)
	}
	_ = conn.Close()
	return true, ""
}

// jobFromAgent turns an agent reply into what the client polls for.
func jobFromAgent(res map[string]interface{}, fallbackLabel string) jobView {
	label := strings.TrimSpace(agentString(res, "action") + " " + agentString(res, "service"))
	if label == "" {
		label = fallbackLabel
	}
	state := agentString(res, "state")
	switch state {
	case "running", "done", "failed":
	case "":
		state = "done"
	default:
		state = "failed"
	}
	return jobView{
		ID:     agentString(res, "job_id"),
		State:  state,
		Label:  label,
		Output: agentString(res, "output"),
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
				// A service switched off on purpose is not a fault, and
				// reporting it as one is how a colour stops meaning anything.
				// `corex manage disable` records the intent in state.json,
				// which is the only place that distinguishes the two.
				if !entry.Enabled {
					status = "DISABLED"
				} else {
					status = "UNHEALTHY"
				}
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
		// to the name the user moved away from. n8n accepts a space separated
		// list, whose first entry is the primary one.
		if name == "n8n" && state.N8nSubdomain != "" && state.Domain != "" {
			first := strings.Fields(strings.Trim(state.N8nSubdomain, "\"'"))
			if len(first) > 0 {
				urls = []string{"https://" + first[0] + "." + state.Domain}
			}
		}
		if name == "calcom" && state.CalcomSubdomain != "" && state.Domain != "" {
			urls = []string{"https://" + strings.Trim(state.CalcomSubdomain, "\"'") + "." + state.Domain}
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
			Enabled:   entry.Enabled,
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

// ── Route handlers ────────────────────────────────────────────────────────────

func stateHandler(w http.ResponseWriter, r *http.Request) {
	state := loadState()
	sys := getSysInfo(state)
	ok, agentErr := agentReachable()
	writeJSON(w, http.StatusOK, hostInfo{
		Version:    state.Version,
		Domain:     state.Domain,
		ServerIP:   state.ServerIP,
		SSHPort:    sys["ssh_port"],
		Hostname:   sys["hostname"],
		Kernel:     sys["kernel"],
		Uptime:     sys["uptime"],
		Docker:     sys["docker"],
		Timezone:   state.Timezone,
		AgentOK:    ok,
		AgentError: agentErr,
	})
}

func servicesHandler(w http.ResponseWriter, r *http.Request) {
	svcs := getServices(loadState())
	if svcs == nil {
		svcs = []ServiceInfo{}
	}
	writeJSON(w, http.StatusOK, svcs)
}

func storageHandler(w http.ResponseWriter, r *http.Request) {
	out, err := runManage("storage")
	if err != nil {
		// Reported, not swallowed. Discarding it is why the Storage tab
		// silently showed nothing for so long: corex-manage refused to run as
		// nobody and the message went into the void.
		log.Printf("storage: corex-manage storage failed: %v (output: %q)", err, out)
		if strings.TrimSpace(out) == "" {
			writeErr(w, http.StatusInternalServerError, fmt.Sprintf("corex manage storage failed: %v", err))
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"output": out})
}

// portsHandler lists the direct ports worth knowing, for the services that are
// actually installed. The previous version hardcoded all of them in the
// template, so it advertised Grafana and Open WebUI on a box that has neither.
func portsHandler(w http.ResponseWriter, r *http.Request) {
	state := loadState()
	ip := state.ServerIP
	if ip == "" {
		ip = "SERVER_IP"
	}
	type candidate struct {
		svc, service, url, note string
	}
	all := []candidate{
		{"portainer", "Portainer", "https://" + ip + ":9443", "Docker UI, its own certificate"},
		{"adguard", "AdGuard", "http://" + ip + ":3000", "setup wizard only, port moves to 80 after"},
		{"monitoring", "Grafana", "http://" + ip + ":3002", "metrics"},
		{"monitoring", "Uptime Kuma", "http://" + ip + ":3001", "status page"},
		{"immich", "Immich", "http://" + ip + ":2283", "photos over the LAN"},
		{"n8n", "n8n", "http://" + ip + ":5678", "workflows"},
		{"ai", "Open WebUI", "http://" + ip + ":3003", "AI chat, LAN only"},
		{"timemachine", "Time Machine", "smb://" + ip + "/CoreX_Backup", "SMB, not HTTP"},
		{"coolify", "Coolify", "http://" + ip + ":8000", "its own stack"},
		{"traefik", "Traefik API", "127.0.0.1:8080", "loopback only, needs an SSH tunnel"},
	}
	rows := []portRow{}
	for _, c := range all {
		if entry, ok := state.Services[c.svc]; !ok || !entry.Installed {
			continue
		}
		rows = append(rows, portRow{Service: c.service, URL: c.url, Note: c.note})
	}
	writeJSON(w, http.StatusOK, rows)
}

// serviceActionHandler handles POST /api/service/<name>/<action>
func serviceActionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/api/service/"), "/", 2)
	if len(parts) != 2 {
		writeErr(w, http.StatusBadRequest, "path must be /api/service/<name>/<action>")
		return
	}
	svcName, action := parts[0], parts[1]

	// Only known service names, and only the agent's own whitelist. Anything
	// destructive is absent from both: remove, replace and migrate stay on
	// SSH, so a stolen session cannot destroy data.
	if _, ok := serviceLabels[svcName]; !ok {
		writeErr(w, http.StatusBadRequest, "unknown service: "+svcName)
		return
	}
	switch action {
	case "start", "stop", "restart", "repair", "update":
	default:
		writeErr(w, http.StatusBadRequest, "unknown action: "+action)
		return
	}

	res, err := agentCall(map[string]interface{}{"action": action, "service": svcName}, 60*time.Second)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	if !agentOK(res) {
		writeErr(w, http.StatusBadGateway, agentString(res, "error"))
		return
	}
	job := jobFromAgent(res, action+" "+svcName)
	if job.ID != "" && !jobIDRe.MatchString(job.ID) {
		writeErr(w, http.StatusBadGateway, "the agent returned a malformed job id")
		return
	}
	if job.ID != "" {
		job.State = "running"
	}
	writeJSON(w, http.StatusOK, job)
}

func cleanupHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	// The dry run is read-only and quick, so it answers inline. A real cleanup
	// prunes images and build cache and can run for minutes, so it becomes a
	// job like any other action.
	if r.URL.Query().Get("dry_run") == "1" {
		out, err := runManage("cleanup", "--dry-run")
		state := "done"
		if err != nil {
			state = "failed"
			if strings.TrimSpace(out) == "" {
				out = err.Error()
			}
		}
		writeJSON(w, http.StatusOK, jobView{State: state, Label: "cleanup --dry-run", Output: out})
		return
	}

	res, err := agentCall(map[string]interface{}{"action": "cleanup"}, 60*time.Second)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	if !agentOK(res) {
		writeErr(w, http.StatusBadGateway, agentString(res, "error"))
		return
	}
	job := jobFromAgent(res, "cleanup")
	if job.ID != "" {
		job.State = "running"
	}
	writeJSON(w, http.StatusOK, job)
}

// jobHandler serves GET /api/job/<id>, which the client polls while an action
// runs. Actions are asynchronous because repair and update outlast any
// sensible request timeout, and a button that appears to hang is how you end
// up clicking it twice.
func jobHandler(w http.ResponseWriter, r *http.Request) {
	jobID := strings.TrimPrefix(r.URL.Path, "/api/job/")
	if !jobIDRe.MatchString(jobID) {
		writeErr(w, http.StatusBadRequest, "bad job id")
		return
	}
	res, err := agentCall(map[string]interface{}{"action": "job", "job_id": jobID}, 30*time.Second)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	if !agentOK(res) {
		writeErr(w, http.StatusBadGateway, agentString(res, "error"))
		return
	}
	job := jobFromAgent(res, "job "+jobID)
	job.ID = jobID
	writeJSON(w, http.StatusOK, job)
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
