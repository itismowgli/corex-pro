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
}

type ServiceEntry struct {
	Installed bool `json:"installed"`
	Enabled   bool `json:"enabled"`
}

type ServiceInfo struct {
	Name      string
	Label     string
	Status    string // HEALTHY | UNHEALTHY | MISSING
	URL       string
	Container string
}

type PageData struct {
	State   CoreXState
	Tab     string
	Content template.HTML
}

// ── Service metadata ──────────────────────────────────────────────────────────

var serviceLabels = map[string]string{
	"traefik":     "Traefik — Reverse Proxy",
	"adguard":     "AdGuard Home — DNS & Ad Blocker",
	"portainer":   "Portainer — Container Manager",
	"nextcloud":   "Nextcloud — File Storage",
	"immich":      "Immich — Photo Library",
	"vaultwarden": "Vaultwarden — Password Manager",
	"n8n":         "n8n — Workflow Automation",
	"stalwart":    "Stalwart — Mail Server",
	"ai":          "AI Stack — Ollama + WebUI",
	"crowdsec":    "CrowdSec — Intrusion Prevention",
	"uptime-kuma": "Uptime Kuma — Service Monitor",
	"monitoring":  "Grafana + Prometheus",
	"timemachine": "Time Machine — Mac Backup",
	"dashboard":   "CoreX Dashboard",
	"coolify":     "Coolify — App Platform",
}

// Primary subdomain per service (for URL construction)
var serviceSubdomains = map[string]string{
	"traefik":     "traefik",
	"adguard":     "adguard",
	"portainer":   "portainer",
	"nextcloud":   "nextcloud",
	"immich":      "immich",
	"vaultwarden": "vault",
	"n8n":         "n8n",
	"stalwart":    "mail",
	"ai":          "ai",
	"uptime-kuma": "status",
	"monitoring":  "grafana",
	"dashboard":   "dashboard",
	"coolify":     "coolify",
}

// Primary container name per service (used for status check and log streaming)
var serviceContainers = map[string]string{
	"traefik":     "traefik",
	"adguard":     "adguard",
	"portainer":   "portainer",
	"nextcloud":   "nextcloud",
	"immich":      "immich-server",
	"vaultwarden": "vaultwarden",
	"n8n":         "n8n",
	"stalwart":    "stalwart",
	"ai":          "ollama",
	"crowdsec":    "crowdsec",
	"uptime-kuma": "uptime-kuma",
	"monitoring":  "grafana",
	"timemachine": "timemachine",
	"dashboard":   "corex-dashboard",
	"coolify":     "coolify",
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
	if err == nil {
		_ = json.Unmarshal(data, &s)
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

		url := ""
		if sub, ok := serviceSubdomains[name]; ok && state.Domain != "" {
			url = "https://" + sub + "." + state.Domain
		}

		label := serviceLabels[name]
		if label == "" {
			label = name
		}

		svcs = append(svcs, ServiceInfo{
			Name:      name,
			Label:     label,
			Status:    status,
			URL:       url,
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
		out, _ := runManage("storage")
		err := tmpl.ExecuteTemplate(&buf, "storage.html", struct {
			Output string
			State  CoreXState
		}{out, state})
		if err != nil {
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
