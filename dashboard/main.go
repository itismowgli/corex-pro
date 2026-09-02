package main

import (
	"bufio"
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
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
	"adguard":     {"http://{IP}:3000"},
	"ai":          {"https://ai.{DOMAIN}"},
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
	validActions := map[string]bool{"start": true, "stop": true, "update": true}
	if !validActions[action] {
		http.Error(w, "unknown action", 400)
		return
	}

	manageAction := map[string]string{
		"start":  "enable",
		"stop":   "disable",
		"update": "update",
	}[action]

	out, err := runManage(manageAction, svcName)

	colorClass := "text-green-400"
	statusLabel := "done"
	if err != nil {
		colorClass = "text-red-400"
		statusLabel = "failed"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w,
		`<pre class="rounded p-3 text-xs bg-gray-950 %s overflow-auto max-h-48 font-mono whitespace-pre-wrap">$ %s %s&#10;%s&#10;<span class="text-gray-500">— %s</span></pre>`,
		colorClass,
		template.HTMLEscapeString(action),
		template.HTMLEscapeString(svcName),
		template.HTMLEscapeString(out),
		statusLabel,
	)
}

func cleanupHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	args := []string{"cleanup"}
	if r.URL.Query().Get("dry_run") == "1" {
		args = append(args, "--dry-run")
	}
	out, err := runManage(args...)
	colorClass := "text-green-400"
	if err != nil {
		colorClass = "text-yellow-400"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w,
		`<pre class="rounded p-3 text-xs bg-gray-950 %s overflow-auto max-h-64 font-mono">%s</pre>`,
		colorClass, template.HTMLEscapeString(out),
	)
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
