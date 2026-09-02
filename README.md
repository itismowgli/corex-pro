<div align="center">
  <img src="https://img.shields.io/badge/CoreX_Pro-v3.12.1-blue?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Version">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</div>

# CoreX Pro

Self-hosted infrastructure for one machine at home. One command installs Docker,
a reverse proxy with HTTPS, a firewall, encrypted backups, and whichever of the
16 services you want.

The design splits storage in two. Ubuntu and the Docker engine live on the
internal disk. Everything you care about keeping lives on an external SSD at
`/mnt/corex-data`. Moving to new hardware means moving one drive.

```bash
curl -fsSL https://raw.githubusercontent.com/itismowgli/corex-pro/main/corex.sh | sudo bash
```

## Contents

- [Who this is for](#who-this-is-for)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Services](#services)
- [Commands](#commands)
- [The CoreX Dashboard](#the-corex-dashboard)
- [HTTPS and certificates](#https-and-certificates)
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [LAN fast path](#lan-fast-path)
- [Outbound email](#outbound-email)
- [Monitoring and alerting](#monitoring-and-alerting)
- [Control from Telegram](#control-from-telegram)
- [Thermal protection](#thermal-protection)
- [UPS monitoring](#ups-monitoring)
- [Backups](#backups)
- [Security](#security)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Ports](#ports)
- [Uninstall](#uninstall)
- [Adding a service](#adding-a-service)

## Who this is for

You can follow instructions and use a terminal, but you do not want to spend
weeks learning nginx, ACME, Docker networking, and Linux hardening before your
photos sync.

You do not need a public IP, a static IP, or access to your router. Cloudflare
Tunnel handles external access with an outbound connection, so CoreX works
behind CGNAT, in a rented flat, or on a phone hotspot.

## Requirements

- A machine running Ubuntu 24.04 LTS with at least 8GB RAM. 16GB or more if you
  want Immich or the AI stack.
- An external SSD. 500GB works; 1TB or more is better if you plan to store
  photos.
- A domain with DNS on Cloudflare. The free plan is enough. You can also run in
  local-only mode without a domain.
- Root access.

Mail is the one thing a home connection usually cannot do. See
[Outbound email](#outbound-email) for how to check yours and what to do
instead.

## Quickstart

```bash
git clone https://github.com/itismowgli/corex-pro.git
cd corex-pro
sudo bash corex.sh install
```

The installer asks for your domain, your email, a timezone, and which services
you want, then generates every password itself. Nothing is left at a default.

When it finishes, read `/root/CoreX_Dashboard_Credentials.md`. It lists every
URL and login. Passwords are also in `/root/corex-credentials.txt`, mode 600.

Re-running the installer on an existing machine is safe. It checks what is
already there, repairs what is broken, and leaves your data alone. Passwords
are loaded from the credentials file rather than regenerated, so you will not
get locked out of your own databases.

## Services

Sixteen service modules, all optional except Traefik. A module can deploy more
than one container: `monitoring` and `ai` each start three.

| Module | What it gives you | Replaces |
|---|---|---|
| `traefik` | Reverse proxy, automatic HTTPS, routing by Docker label | nginx plus certbot |
| `adguard` | Network-wide DNS with ad and tracker blocking | Pi-hole |
| `nextcloud` | Files, calendar, contacts, photo albums, collaborative docs | Dropbox, Google Drive |
| `immich` | Photo and video library with search and face grouping | Google Photos |
| `vaultwarden` | Password manager, works with every Bitwarden client | 1Password, LastPass |
| `stalwart` | Mail server with SMTP, IMAP, and JMAP | see the email section first |
| `n8n` | Workflow automation with several hundred integrations | Zapier |
| `coolify` | Deploy apps from Git, installed manually, routed by address | Heroku, Vercel |
| `timemachine` | Time Machine target over SMB for Macs | Time Capsule |
| `monitoring` | Uptime Kuma, Grafana, and Prometheus | Datadog |
| `ai` | Ollama, Open WebUI, and Browserless | ChatGPT subscription |
| `crowdsec` | Intrusion detection that blocks attackers via iptables | Fail2ban, extended |
| `portainer` | Container management in a browser | docker CLI |
| `cloudflared` | Cloudflare Tunnel connector | port forwarding |
| `dashboard` | CoreX web GUI for daily operations | SSH |
| `ups` | Graceful shutdown on power loss, using NUT | nothing, usually |

Add or remove any of them later:

```bash
sudo bash corex-manage.sh add immich
sudo bash corex-manage.sh remove n8n
```

### Where each service answers

Only the addresses below exist. Anything else, `immich.yourdomain.com` or
`adguard.yourdomain.com` for instance, resolves to nothing, because a hostname
only works if a Traefik Host rule declares it. The rules live in
`lib/services/*.sh` and are the source of truth for this table.

| Service | Address | Certificate |
|---|---|---|
| `nextcloud` | `https://nextcloud.DOMAIN` | Let's Encrypt |
| `immich` | `https://photos.DOMAIN` | Let's Encrypt |
| `vaultwarden` | `https://vault.DOMAIN` | Let's Encrypt |
| `stalwart` | `https://mail.DOMAIN` | Let's Encrypt |
| `n8n` | `https://n8n.DOMAIN` | Let's Encrypt |
| `ai` | `https://ai.DOMAIN` | Let's Encrypt |
| `monitoring` | `https://grafana.DOMAIN` and `https://status.DOMAIN` | Let's Encrypt |
| `portainer` | `https://portainer.DOMAIN` | Let's Encrypt |
| `dashboard` | `https://dashboard.DOMAIN` | Let's Encrypt |
| `nextcloud` whiteboard | `https://whiteboard.DOMAIN` | Let's Encrypt |
| `adguard` | `http://SERVER_IP:3000` | none, plain HTTP on the LAN |
| `coolify` | `https://coolify.DOMAIN`, and `http://SERVER_IP:8000` | Let's Encrypt |
| `traefik` | `http://127.0.0.1:8080`, reachable only through an SSH tunnel | none |
| `timemachine` | `smb://SERVER_IP/CoreX_Backup` | not applicable |
| `crowdsec`, `cloudflared`, `ups` | no browsable address | not applicable |

Coolify is the one exception to how routes are declared. It installs its own
stack on its own Docker network with no interface on `proxy-net`, so
`coolify:8080` does not resolve from Traefik and a Docker label cannot describe
the backend. Traefik reaches it by address instead, through a rule written into
its file-provider directory at
`docker-configs/traefik/dynamic/coolify.yml`. That file lives outside
Coolify's own compose, which Coolify rewrites on upgrade. Set the same URL as
Coolify's Instance FQDN in its settings, or it keeps generating links back to
port 8000.

Every Traefik router uses the same entrypoint and the same resolver
(`websecure` and `myresolver`), so all eleven hostnames present a Let's Encrypt
certificate. If one of them shows a certificate warning while the others do
not, the router exists but ACME has not issued for that name yet. Check
`docker logs traefik 2>&1 | grep -i acme`.

The CoreX Dashboard builds its links from this same list, so a link it shows is
a name that resolves.

## Commands

```bash
sudo bash corex.sh install              # interactive installer
sudo bash corex.sh doctor               # health check, then repair what is broken
sudo bash corex.sh update               # pull the latest CoreX Pro
sudo bash corex.sh migrate              # change domain across every service
sudo bash corex.sh nuke                 # uninstall

sudo bash corex-manage.sh status        # what is running, and how it is doing
sudo bash corex-manage.sh list          # every available service
sudo bash corex-manage.sh add <svc>     # install one
sudo bash corex-manage.sh remove <svc>  # remove one, asks about the data
sudo bash corex-manage.sh update --all  # pull new images for everything
sudo bash corex-manage.sh repair <svc>  # regenerate config and recreate
sudo bash corex-manage.sh health        # host hardware: temperature, SMART, dpkg
sudo bash corex-manage.sh storage       # disk usage by service
sudo bash corex-manage.sh cleanup       # reclaim space safely
sudo bash corex-manage.sh os-upgrade    # supervised OS upgrade with safety gates
sudo bash corex-manage.sh mail-setup    # configure Nextcloud outbound email
sudo bash corex-manage.sh lan-setup     # route LAN traffic locally, not via Cloudflare
sudo bash corex-manage.sh network-tune  # kernel tuning for gigabit transfers
sudo bash corex-manage.sh network-check # test HTTPS, certificate expiry, and DNS
sudo bash corex-manage.sh watchdog      # resource alerting: what is degrading the box
sudo bash corex-manage.sh restart <svc> # restart its containers, nothing else
sudo bash corex-manage.sh agent         # the agent behind the buttons and the bot
```

`repair` regenerates a service's compose file before recreating the container,
so a CoreX fix to an environment variable, a resource limit, or a Traefik label
reaches an install that was set up months ago. `doctor` runs `repair` on
anything unhealthy, which makes it the command to run after an update.

## The CoreX Dashboard

A web GUI for the things you do often, so you do not need SSH for them.

CoreX builds the image on your server from `dashboard/`, so there is no
registry to depend on. The first install spends a minute or two compiling.

```bash
sudo bash corex-manage.sh add dashboard
```

### Signing in

| | |
|---|---|
| URL | `https://dashboard.yourdomain.com` |
| Username | `admin` |
| Password | generated at install, see below |

Traefik enforces HTTP Basic auth in front of it. To read the password:

```bash
sudo cat /mnt/corex-data/docker-configs/dashboard/.dashboard-password
```

To change it:

```bash
sudo DASHBOARD_PASS='your-new-password' bash corex-manage.sh repair dashboard
```

The password survives repairs. It is stored in that file, mode 600, rather than
regenerated each run.

### What the tabs do

The Services tab shows a health badge per service with buttons to start, stop,
update, or repair, and streams container logs. Storage breaks usage down by
service and can trigger a cleanup. Network lists every service URL with its
status and certificate expiry. System shows host details and a command
reference.

Every button shells out to `corex-manage.sh`, so the GUI and the CLI cannot
drift apart. Service names and actions are checked against an allowlist on the
server.

### Reaching it

On the LAN, `dashboard.yourdomain.com` has to resolve to your server.
`corex manage lan-setup` arranges that through AdGuard. Failing that, add a
hosts entry on your laptop.

From outside, the dashboard is not published through Cloudflare Tunnel unless
you add a public hostname for it yourself:

```
Subdomain: dashboard    Service: http://corex-dashboard:8080
```

Think about that one before you do it. The dashboard can stop and update every
service on the box, and Basic auth over HTTPS is all that stands in front. LAN
only is the safer default, or put Cloudflare Access in front of the hostname.

### The Traefik dashboard is a different thing

Traefik has its own dashboard, and CoreX binds it to the server's loopback
because it exposes your full routing table. Docker published ports skip UFW, so
binding it anywhere else would put it on your LAN. Reach it over SSH:

```bash
ssh -L 8080:127.0.0.1:8080 youruser@your-server
# then open http://localhost:8080/dashboard/ on your own machine
```

## HTTPS and certificates

Traefik gets certificates from Let's Encrypt and renews them without being
asked. Which challenge it uses matters a great deal on a home connection.

### Use DNS-01 if your ISP blocks ports

The default challenge, TLS-ALPN-01, needs Let's Encrypt to reach port 443 on
your server from the internet. Most residential ISPs block that, and CGNAT
makes it impossible either way. Check yours:

```bash
PUB=$(curl -s https://api.ipify.org)
for p in 80 443; do nc -z -G 8 "$PUB" $p && echo "$p open" || echo "$p blocked"; done
```

If either is blocked, use DNS-01 instead. It proves you control the domain by
writing a TXT record through the Cloudflare API, so it needs no inbound
connectivity at all, and it can issue wildcards.

1. Go to dash.cloudflare.com, then My Profile, then API Tokens, then Create
   Token.
2. Use the "Edit zone DNS" template.
3. Under Zone Resources, include only your zone.
4. Create the token and copy it.

```bash
sudo EMAIL='you@example.com' CLOUDFLARE_DNS_API_TOKEN='your-token' \
  bash corex-manage.sh repair traefik
```

Certificates appear within a minute or so. Check:

```bash
sudo jq -r '.myresolver.Certificates | length' \
  /mnt/corex-data/docker-configs/traefik/acme.json
```

Rotate the token whenever you like. Existing certificates keep working, since
the token is only needed at renewal, roughly every 60 days. Create a new one,
apply it with the same command, then delete the old one in Cloudflare.

### If Let's Encrypt cannot work

CoreX generates its own certificate authority and a wildcard certificate for
your domain, and uses it as Traefik's default certificate. Install the CA on
each device and you get a clean padlock on your LAN:

```bash
scp your-server:/mnt/corex-data/docker-configs/traefik/certs/ca.crt ~/corex-ca.crt

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/corex-ca.crt
```

On iOS, AirDrop the file, then enable it under Settings, General, About,
Certificate Trust Settings. On Android, use Settings, Security, Encryption,
Install from storage.

CoreX writes that default certificate only when no DNS token is configured. A
wildcard default matches every hostname, which satisfies Traefik's TLS lookup
and stops it from ever asking Let's Encrypt for anything. With a token
present, real certificates cover every route and no device needs the CA.

## Cloudflare Tunnel

The `cloudflared` container opens an outbound connection to Cloudflare and
holds it. Requests arrive over that connection, so nothing has to be reachable
from the internet and you never touch your router. DDoS protection and the WAF
come with it on the free plan.

### Setting it up

Add your domain to Cloudflare and point your registrar's nameservers at the two
Cloudflare gives you. Wait for the dashboard to show the domain as Active.

At one.dash.cloudflare.com, go to Networks, then Tunnels, then Create a tunnel.
Pick Cloudflared as the connector and name it. On the install screen, ignore
the install commands, because CoreX runs the connector for you. You only need
the token, which is the long string after `--token`.

```bash
sudo CLOUDFLARE_TUNNEL_TOKEN='eyJhIjoi...' bash corex.sh install

# or on an install that already exists
sudo CLOUDFLARE_TUNNEL_TOKEN='eyJhIjoi...' bash corex-manage.sh repair cloudflared
```

Confirm the connector registered:

```bash
sudo docker logs cloudflared --tail 20   # look for "Registered tunnel connection"
```

### Public hostnames use container names

For each service you want reachable from outside, add a Public Hostname under
your tunnel:

The simplest configuration is one wildcard hostname pointing at Traefik:

| Hostname | Service | Additional settings |
|---|---|---|
| `*.yourdomain.com` | `https://traefik:443` | turn No TLS Verify on |

Traefik then routes by Host header for external traffic exactly as it does on
the LAN, which matters more than it sounds. Anything Traefik adds, the
`noindex` header, HSTS, the CalDAV redirect, applies only to traffic that
passes through it, so a tunnel pointing straight at containers leaves external
visitors, including search engine crawlers, outside all of it. A container port
change also cannot break the tunnel any more, and a new service needs no
Cloudflare work.

No TLS Verify is needed because Traefik presents a certificate for the public
hostname while cloudflared connects to the name `traefik`, so verification
fails on a name mismatch. That hop is inside the Docker network.

Per-service hostnames also work, and are what CoreX documented previously:

| Subdomain | Service | Tunnel URL |
|---|---|---|
| `nextcloud` | Nextcloud | `http://nextcloud:80` |
| `photos` | Immich | `http://immich-server:2283` |
| `vault` | Vaultwarden | `http://vaultwarden:80` |
| `n8n` | n8n | `http://n8n:5678` |
| `mail` | Stalwart admin and webmail | `http://stalwart:8080` |
| `ai` | Open WebUI | `http://open-webui:8080` |
| `grafana` | Grafana | `http://grafana:3000` |
| `status` | Uptime Kuma | `http://uptime-kuma:3001` |
| `whiteboard` | Nextcloud whiteboard backend | `http://nextcloud-whiteboard:3002` |
| `portainer` | Portainer | `https://portainer:9443`, with No TLS Verify on |

Immich answers on `photos`, not `immich`. The subdomain is set by the Traefik
Host rule in `lib/services/immich.sh`, so that is the name to use here and the
only name that will resolve.

The URL has to be the container name and its internal port. This is where most
setups go wrong. `cloudflared` runs inside the `proxy-net` Docker network, so
`localhost` means the cloudflared container itself, which serves nothing.
`nextcloud:80` resolves through Docker's DNS.

Use the internal port too. Grafana publishes `3002:3000` on the host, but the
tunnel URL is `http://grafana:3000`.

Cloudflare creates the DNS records for you.

### Keeping the domain out of search results

Every route carries a `noindex` directive, set once as a middleware on
Traefik's `websecure` entrypoint so it covers services added later:

```
X-Robots-Tag: noindex, nofollow, noarchive, nosnippet, noimageindex, notranslate
```

`robots.txt` is not the mechanism. It asks a crawler not to fetch a URL, but a
URL that was never fetched can still be indexed from an external link and
listed without a snippet. `noindex` is the directive that removes it. Both are
requests rather than enforcement, so neither substitutes for authentication.

Check it, from outside rather than the LAN, because the two paths differ:

```bash
curl -sI https://nextcloud.yourdomain.com/ | grep -i x-robots-tag
```

If that comes back empty, the tunnel is pointing at containers rather than at
Traefik, so the header never gets added. See the wildcard hostname above.

Certificates are the other way a hostname becomes public. Let's Encrypt
publishes every certificate it issues to the Certificate Transparency logs, so
a certificate per hostname advertises every hostname at crt.sh. With a
Cloudflare DNS token configured, CoreX requests a single wildcard instead, and
the individual names never appear. Check what is already listed:

```bash
curl -s 'https://crt.sh/?q=%25.yourdomain.com&output=json' | grep -o '"name_value":"[^"]*"'
```

### What to leave off the internet

Publish only what you need. AdGuard's admin panel, Portainer, n8n, Coolify and
the CoreX Dashboard can all take control of the machine, so keep them on the
LAN or put Cloudflare Access in front of them. n8n runs arbitrary code in a
workflow node, Portainer holds the Docker socket, and Coolify deploys to the
host, so each one is equivalent to a shell.

Chrome gives a second, more surprising reason. Google Safe Browsing flagged
both `portainer.` and `n8n.` on a working install as a **"Dangerous site"**,
with a full red interstitial. Neither was compromised: one workflow, no
CrowdSec decisions, nothing in the logs. A generic admin login form on a
domain with no reputation history matches its phishing heuristics, and
Nextcloud and Vaultwarden escape only because their login pages are
recognisable. Publishing an admin panel therefore costs you a browser warning
as well as the exposure. Removing the Public Hostname clears both. If you need
it from outside, request a review at Google Search Console after verifying the
domain, and put Cloudflare Access in front.

## LAN fast path

By default a laptop on your own network resolves `nextcloud.yourdomain.com` to
Cloudflare, so a local upload leaves your house and comes back. `lan-setup`
points LAN clients at the server's local address instead:

```bash
sudo bash corex-manage.sh lan-setup
```

A DNS override alone is not enough, because browsers have four other ways to
reach Cloudflare anyway. `lan-setup` deals with all of them: SVCB and HTTPS DNS
records that carry Cloudflare's addresses, Chrome's cached QUIC connections,
Chrome's built-in DNS client, and IPv6 records pointing at Cloudflare's edge.

Do not add a second DNS server alongside AdGuard. Some queries will go to the
fallback, come back with a Cloudflare address, and send that traffic out over
the internet again.

## Outbound email

Nextcloud cannot send password resets, share notifications, or activity digests
until SMTP is set up. Its own warning says the configuration is "not set or
verified" without mentioning what breaks.

Self-hosting mail on a home connection usually cannot work, whichever mail
server you run. Check before you try:

```bash
PUB=$(curl -s https://api.ipify.org)

nc -z -G 8 "$PUB" 25 && echo "inbound 25 open" || echo "inbound 25 blocked"
timeout 8 bash -c 'cat </dev/null >/dev/tcp/aspmx.l.google.com/25' \
  && echo "outbound 25 open" || echo "outbound 25 blocked"
dig +short -x "$PUB"    # empty means no reverse DNS
```

Most residential ISPs block port 25 in both directions, and you cannot set a
PTR record on a residential address, which by itself makes Gmail and Outlook
reject or spam-file your mail. Cloudflare Tunnel does not help here, because
the free tunnel carries HTTP and not SMTP.

Submission on port 587 is normally open, so relaying through a provider works
where direct delivery does not:

```bash
sudo NC_SMTP_HOST=smtp.gmail.com \
     NC_SMTP_USER=you@gmail.com \
     NC_SMTP_PASS='abcd efgh ijkl mnop' \
     bash corex-manage.sh mail-setup
```

Run it without arguments to be prompted instead, with the password hidden. It
picks the encryption mode from the port, since 587 uses STARTTLS and 465 uses
implicit TLS, and getting that wrong is the usual cause of "email could not be
sent". It also checks the port is reachable before you start suspecting your
password.

Gmail needs an App Password from myaccount.google.com/apppasswords, not your
account password, and the option only appears once 2-Step Verification is on.
Brevo, Fastmail, Resend, and Postmark all work the same way.

Test it:

```bash
sudo docker exec -u www-data nextcloud php occ mail:test you@example.com
```

For incoming mail, Cloudflare Email Routing forwards `you@yourdomain.com` to a
mailbox you already have, for free. It takes over your MX record, so a
self-hosted mail server must not also claim it.

Stalwart is included for people who do have a public IP and can set a PTR
record, which in practice means a small VPS. On a home line it can still serve
mailboxes over IMAP on your LAN, but it will not exchange mail with the
internet.

## Monitoring and alerting

There are two layers, and they answer different questions.

Uptime Kuma answers "is the service reachable". It checks each service over
HTTPS every 60 seconds and notifies you when one stops answering. Set up a
notification channel in Kuma first, at `https://status.yourdomain`, then the
monitors use it.

One thing to get right: Kuma accepts only HTTP 200 to 299 by default, and
several services legitimately answer something else. Nextcloud and AdGuard
redirect to a login page (302), and the dashboard returns 401 because it sits
behind basic auth. Left at the default those three report permanently down,
which is worse than no monitoring because it teaches you to ignore the alerts.
Add the code each service actually returns under Accepted Status Codes.

The watchdog answers "what is degrading the box". Reachability checks miss most
of what goes wrong on small hardware: a container that is OOM-killed and
restart-looping, a disk filling up, load shedding in progress, or one
background container consuming five cores. None of that changes a 200 OK. Nor
can an HTTP check cover a container that has no URL, such as a database, a
Redis cache, or Nextcloud's cron.

Six checks run every 60 seconds:

| Check | Alerts when |
|---|---|
| CPU temperature | at or above 80C, or no sensor is installed |
| CPU load | 5-minute load average above 1.5 per core |
| Memory pressure | under 15% RAM available, or swap above 25% |
| Disk space | under 10% free on the OS disk, or 15% on the SSD |
| Container health | a container is stopped while set to restart, is unhealthy, was OOM-killed, or is restart-looping |
| Thermal shedding | the guardian currently has services stopped |

Every alert names the containers responsible, and says what to run about it.
Setup also applies a Telegram message template, so alerts arrive with the
verdict and the service on the first line and the detail below:

```
🔴 Down  Container Health

Stopped but set to restart: timemachine
Restart-looping: n8n (3x)
Cause: docker logs --tail 30 timemachine
```

```
🔴 Down  CPU Temperature

88C, over the 80C limit.
Heaviest: immich-ml 190%, nextcloud 52%
```

If you already wrote your own template in Kuma, setup leaves it alone.

The container check reads restart policy as intent, so a service switched off
with `corex-manage.sh disable` does not alert. That is what makes it safe to
leave running on a box where some services are deliberately stopped.

Results are delivered through Uptime Kuma, using whatever notification channel
you already configured there. Set it up with:

```bash
sudo bash corex-manage.sh watchdog setup   # install and register the monitors
sudo bash corex-manage.sh watchdog         # state, thresholds, recent findings
sudo bash corex-manage.sh watchdog run     # one cycle now, printed
sudo bash corex-manage.sh watchdog test    # send a real alert, end to end
```

Thresholds live in `/etc/corex/watchdog.conf`. Set `WATCHDOG_ENABLED=false`
there to stop it without uninstalling.

Kuma cannot alert on its own unavailability, so nothing here covers Kuma being
down. If that matters, add an external check from outside the machine.

## Control from Telegram

Send a command in the same chat that receives the alerts:

```
stop immich
restart n8n
update all
logs nextcloud 60
status
health
```

The bot replies straight away, and sends a second message when the job
finishes, saying what changed rather than just that it is done. Send `help` for
the full list.

Replies are reshaped for a phone rather than forwarded from the terminal.
`status` groups services by state and names only the ones needing attention.
`health` and `storage` keep their numbers as wrapping text and put only their
tables in monospace, which is the one place alignment matters.

It takes its bot token and chat id from the Telegram notification you set up in
Uptime Kuma, so there is nothing extra to configure. Commands from any other
chat are logged and ignored.

The dashboard's Start, Stop, Restart, Repair and Update buttons go through the
same path, so both work the same way and neither can do more than the other.

### Why it is built this way

The dashboard runs as `nobody` in a container and `corex-manage.sh` needs root,
so the buttons used to fail with "Run as root". Running a web-facing container
as root would hand it the whole machine, and passwordless sudo is the same
thing with extra steps.

Instead there is one privileged process, `corex-agent`, which accepts a fixed
list of actions over a unix socket. The dashboard and the bot are both
unprivileged clients of it:

| Component | What it can do |
|---|---|
| `corex-agent` | root, but only the whitelisted actions |
| `corex-bot` | its own user. Its only privilege is reaching that socket |
| dashboard | joins the same group, still runs as `nobody` |

Available: start, stop, restart, repair, update, cleanup, status, list, health,
storage, logs.

Not available, on purpose: removing a service, replacing one, adding one,
changing the domain, and uninstalling. Everything you can reach is reversible,
so a stolen phone cannot destroy your data. Those operations stay on SSH.

### What to be aware of

Anyone who can post in that chat can stop your services. Treat it the way you
would treat shell access: keep the chat private, and if you lose the device,
revoke the bot token in BotFather.

To point the bot at a different chat, edit `/etc/corex/telegram.conf` and
restart it with `systemctl restart corex-telegram`.

```bash
sudo bash corex-manage.sh agent        # is it running, and what will it run
sudo bash corex-manage.sh agent setup  # install or reinstall it
sudo bash corex-manage.sh agent test   # prove the socket works, including
                                       # from inside the dashboard container
```

## Thermal protection

Small machines often use mobile CPUs in cases with limited cooling. Under
sustained container load they reach their thermal limit and the CPU cuts power
itself. The kernel logs nothing and flushes nothing, so you get a silent crash,
a possibly corrupt database, and a possibly broken package database if it
happened during an upgrade.

CoreX watches the temperature every 30 seconds and sheds container load instead
of waiting for that:

| Temperature | What happens |
|---|---|
| 80C | logged, nothing else |
| 85C | stops containers CoreX did not deploy, then the `ai` services |
| 90C | also stops monitoring, productivity, storage, and backup services |
| 97C | shuts down cleanly rather than letting the hardware cut power |

Containers come back on their own once the temperature drops. Traefik, the
security services, and mail are never stopped, so the machine stays reachable.
Containers deployed outside CoreX go first, because they carry no resource
limits and are usually the reason it got hot.

Thresholds live in `/etc/corex/thermal.conf`. Set `THERMAL_ENABLED=false` to
turn it off. A reading has to hold for three consecutive samples before
anything is stopped, so a brief spike during a backup does not cost you your
services.

Alongside it, `corex-blackbox.timer` writes temperature, load, memory, and
throttle counts to `/mnt/corex-data/blackbox.log` every 20 seconds. When a
machine dies without warning, the last line in that file tells you what killed
it. `corex-boot-repair.service` then runs on the next boot, before the apt
timers, and repairs a package database left half-configured by the crash.

Check the current state with:

```bash
sudo bash corex-manage.sh health
```

## UPS monitoring

CoreX installs NUT on the host rather than in a container, because `upsmon` has
to keep working while Docker is shutting down.

```bash
sudo bash corex-manage.sh add ups
```

It detects a USB UPS automatically. On low battery it stops every container
with a 30 second grace period, which is enough for MariaDB and PostgreSQL to
checkpoint, then halts. Every step has a timeout, so one stuck container cannot
spend the rest of the battery.

```bash
upsc corex-ups@localhost              # live status
upsc corex-ups@localhost battery.runtime
grep ups- /mnt/corex-data/blackbox.log   # events
```

Test it before you rely on it. Unplug the UPS from the wall and check that an
ONBATT event appears in the blackbox log. Finding out during a real outage is
not the time.

If no UPS is connected, NUT is installed but left disabled, because a monitor
configured against a device that is not there can shut the machine down for no
reason.

## Backups

Restic runs nightly at 02:00 and writes an encrypted, deduplicated snapshot to
`/mnt/corex-data/backups/restic-repo`. It keeps 7 daily, 4 weekly, and 6
monthly snapshots.

```bash
sudo /usr/local/bin/corex-backup.sh     # run one now
sudo /usr/local/bin/corex-restore.sh    # interactive restore
sudo restic -r /mnt/corex-data/backups/restic-repo snapshots
```

The repository password is in `/root/corex-credentials.txt`. Do not change it
after setup, because that invalidates the repository and every snapshot in it.

A backup on the same SSD as the data protects you from mistakes and not from
losing the drive. Copy the repository somewhere else as well, whether that is
another disk or object storage.

## Security

The installer moves SSH to a non-default port, disables root login, and allows
only modern ciphers and key exchange algorithms. Fail2ban runs three jails,
including one that gives repeat offenders a 30 day ban. UFW denies inbound
traffic by default. AppArmor is enabled. CrowdSec, if you install it, adds
iptables DROP rules for addresses it sees attacking you.

Kernel parameters cover both hardening and throughput: reverse path filtering,
SYN cookies, no source routing, BBR congestion control, 64MB TCP buffers, and
TCP Fast Open.

`vm.dirty_ratio` is 10 rather than the Linux default. A higher value lets
gigabytes of written data sit in RAM, and an unclean shutdown loses all of it,
which is how databases get corrupted.

Unattended upgrades install security patches, but never the kernel, `libc6`, or
`systemd`. Restricting the origin to `-security` is not enough on its own,
because Ubuntu ships kernel updates through that origin. An unattended kernel
upgrade interrupted by a crash can leave a machine that will not boot. Apply
those deliberately:

```bash
sudo bash corex-manage.sh os-upgrade
```

That command refuses to start if the CPU is above 85C, if the package database
is already dirty, or if the machine has been up for less than 15 minutes.

## Architecture

```
Internal disk                 External SSD (/mnt/corex-data)
  Ubuntu 24.04                  docker-configs/<service>/   generated compose
  /var/lib/docker               service-data/<service>/     databases, uploads
    images, build cache         timemachine-data/           Mac backups
                                backups/restic-repo/        encrypted snapshots
                                blackbox.log                health samples
```

Three Docker networks keep things apart. `proxy-net` carries anything
web-facing plus Traefik and the tunnel. `monitoring-net` isolates Prometheus
and its exporters so they are not reachable from the web. `ai-net` sandboxes
Ollama and Browserless, which matters because Browserless executes code.
Grafana and Open WebUI sit on two networks each, deliberately.

Traefik routes by Docker label, so a service becomes reachable by declaring its
own route. `loadbalancer.server.port` is the container's internal port, not the
host-mapped one.

State lives in `/etc/corex/state.json`: which services are installed, the
domain, the server address, and the SSH port. `corex-manage` and `doctor` read
it to know what they are managing.

## Troubleshooting

Start here:

```bash
sudo bash corex.sh doctor               # service health, then auto-repair
sudo bash corex-manage.sh health        # temperature, SMART, package integrity
sudo bash corex-manage.sh network-check # HTTPS, certificates, DNS per service
```

| Symptom | Cause |
|---|---|
| Browser warns about the certificate | Let's Encrypt has issued nothing. Check `acme.json`, then use DNS-01 |
| 502 through the tunnel | The Public Hostname points at `localhost` or a host port instead of a container name and internal port |
| Cloudflare Error 1033 | `cloudflared` is not running or cannot reach Cloudflare |
| Uploads over 100MB fail | Cloudflare's free plan caps request bodies at 100MB. CoreX sets Nextcloud's chunk size to 10MB for this |
| Slow transfers on the LAN | Traffic is going out through Cloudflare. Run `lan-setup` |
| Nextcloud returns 503 | It is in maintenance mode. `occ maintenance:mode --off`, after any pending upgrade finishes |
| Services stopped by themselves | The thermal guardian shed load. Check `blackbox.log` and the temperature |
| Machine crashes with nothing in the log | Almost certainly heat. The last line of `blackbox.log` will show it |
| Traefik dashboard refuses connections | It is bound to the server's loopback. Use an SSH tunnel |
| The mail hostname returns 502 while the container is healthy | A bot scanned the hostname and Stalwart banned the proxy's container IP, not the bot's. `corex manage repair stalwart` clears it. See below |
| Portainer returns 500 through Traefik but 200 on port 9443 | Its self-signed certificate is issued for `0.0.0.0`, so Traefik cannot verify it. Repair Traefik, then Portainer |
| The dashboard says no services are installed | It cannot read `/etc/corex/state.json`. Check the file's mode, then `docker logs corex-dashboard` |

### Stalwart bans the proxy instead of the scanner

Stalwart bans any IP that probes scanner paths. Behind a proxy the address it
sees is the proxy's, so a single bot request to `mail.DOMAIN//wp-content/.env`
bans cloudflared and cuts off every external visitor at once. The container
stays up and the LAN path keeps working, because Traefik has a different
container IP, which makes it look like a tunnel problem. Only
`docker logs stalwart` names the cause:

```
Banned due to scan (security.scan-ban) remoteIp=172.18.0.11 path="//wp-content/.env"
```

Restarting clears the ban list, which is held in memory. To stop it recurring,
set these two in Stalwart's own settings once initial setup is finished:

| Setting | Value |
|---|---|
| `proxyTrustedNetworks` | `172.16.0.0/12` |
| `useXForwarded` | `true` |

Together they tell Stalwart to trust the Docker network as a proxy and to ban
the real client from the forwarded header. They live in Stalwart's store, so
they cannot be set through environment variables or the compose file.

Traefik logs at INFO, which is where ACME problems show up:

```bash
sudo docker logs traefik 2>&1 | grep -i acme
```

## Ports

| Port | Service | Exposure |
|---|---|---|
| 22 or custom | SSH | LAN, or wherever you allow it |
| 80, 443 | Traefik | public if your ISP permits |
| 53 | AdGuard DNS | LAN |
| 8080 | Traefik dashboard | loopback only |
| 445, 137-139 | Time Machine over SMB | LAN |
| 11434 | Ollama | LAN |
| 25, 587, 465, 143, 993 | Stalwart mail | see the email section |

Everything else reaches you through Traefik on 443.

## Uninstall

```bash
sudo bash nuke-corex.sh --dry-run   # show what would be removed
sudo bash nuke-corex.sh             # remove it
```

The dry run is worth reading first. Removing data requires typing a
confirmation word, and the script tells you which paths it is about to touch.

## Adding a service

Drop one file in `lib/services/` and it appears in the installer wizard,
`corex-manage list`, `doctor`, and `update`. No core file changes.

The file declares its metadata and seven functions:

```bash
SERVICE_NAME="gitea"
SERVICE_LABEL="Gitea, self-hosted Git"
SERVICE_CATEGORY="productivity"   # also drives thermal shed order
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_RAM_MB=512
SERVICE_DISK_GB=5

gitea_dirs()        { ... }   # directories, with the right ownership
gitea_firewall()    { ... }   # UFW rules, if any
gitea_deploy()      { ... }   # write compose, start, record state
gitea_destroy()     { ... }   # stop, optionally remove data
gitea_status()      { ... }   # HEALTHY, UNHEALTHY, or MISSING
gitea_repair()      { ... }   # regenerate compose, then recreate
gitea_credentials() { ... }   # lines for the summary document
```

`SERVICE_CATEGORY` decides when the thermal guardian stops your service, so
pick it accurately. `repair` must regenerate the compose file, or your fixes
will never reach anyone who installed before you shipped them.

Tests run without root or Docker:

```bash
bats test/unit/                      # module contract and thermal logic
bash -n install-corex-master.sh      # parse check
```

## Version history

v1.0.0 shipped a single-file installer with 14 services and Restic backups.
v2.0.0 replaced it with a modular `lib/` layout, a wizard, `state.json`, and
plugin-style services. v2.1.0 automated the LAN fast path. v2.2.0 added network
tuning and hardened SSH, Fail2ban, and the kernel. v2.3.0 and v2.4.x fixed
Nextcloud performance and upload failures. v2.5.0 added storage management and
resource limits. v3.0.0 introduced the web dashboard, a working CrowdSec
bouncer, and `network-check`. v3.1.0 added thermal load shedding, boot-time
package repair, and UPS monitoring. v3.2.x made `repair` regenerate compose
files so fixes reach existing installs, fixed certificate issuance behind
blocked ports, and documented the dashboard and Cloudflare setup. v3.11.0 added
the resource watchdog, so alerts cover memory, disk, heat and container faults
rather than only reachability, and fixed a Time Machine crash loop it found.
v3.12.0 made the dashboard buttons work and added Telegram control, both
through a single privileged agent rather than by granting either of them root.

See [CHANGELOG.md](CHANGELOG.md) for the detail.

## License

MIT. See [LICENSE](LICENSE).
