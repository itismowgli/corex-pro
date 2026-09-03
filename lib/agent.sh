#!/bin/bash
# lib/agent.sh — CoreX Pro
# Action agent and Telegram control bot.
#
# WHY THIS EXISTS
#   The dashboard's buttons never worked. It runs as `nobody` in a container
#   and corex-manage.sh requires root, so every action failed with "Run as
#   root". Both obvious fixes are wrong: running a web-facing container as root
#   hands it the host, and giving it passwordless sudo is the same thing with
#   extra steps.
#
#   So there is one privileged process, corex-agent, with a fixed list of
#   actions it will perform, and two unprivileged clients: the dashboard and
#   the Telegram bot. One place to audit, and a second client adds no new
#   privilege.
#
# THE PRIVILEGE LAYOUT, WHICH IS THE POINT
#   corex-agent   root, listens on a unix socket, runs only whitelisted
#                 corex-manage actions, all of them reversible
#   group         corex-agent, owns the socket at 0660; this is the real
#                 boundary, the bearer token only limits the damage from
#                 getting those permissions wrong
#   corex-bot     the Telegram bot's own user. Its entire privilege is
#                 membership of that group. It cannot read the credentials
#                 file, reach the Docker socket, or remove anything
#   dashboard     joins the same group and gets the socket bind-mounted, so it
#                 keeps running as nobody
#
#   remove, replace, add, nuke and migrate are absent from the whitelist by
#   design, so neither a stolen Telegram account nor a dashboard session can
#   destroy data or an install. Those stay on SSH.
#
# THE DASHBOARD'S ACCOUNTS SIT ON THE SAME SPLIT
#   /etc/corex/dashboard-users.json is 0600 root, so the dashboard reads and
#   writes it through the agent and does the hashing itself. The one thing
#   that never crosses is the mail relay: /etc/corex/smtp.conf is also 0600
#   root, so the agent generates a reset code, mails it and stores only its
#   hash. `corex manage dashboard-user` edits the same file from SSH without
#   the agent, the container or the network, which is what makes a broken
#   login recoverable.

AGENT_GROUP="corex-agent"
AGENT_USER="corex-bot"
AGENT_RUN_DIR="/run/corex"
AGENT_SOCKET="${AGENT_RUN_DIR}/agent.sock"
AGENT_TOKEN_FILE="/etc/corex/agent.token"
AGENT_CONF="/etc/corex/agent.conf"
AGENT_TELEGRAM_CONF="/etc/corex/telegram.conf"
AGENT_LIB_DIR="/usr/local/lib/corex"
AGENT_STATE_DIR="/var/lib/corex-bot"

agent_install() {
    log_info "Installing action agent..."

    local src="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/agent"
    [[ -d "$src" ]] || { log_warning "agent/ sources not found at ${src}"; return 1; }
    command -v python3 &>/dev/null || { log_warning "python3 missing, cannot install the agent"; return 1; }

    _agent_accounts
    _agent_files "$src"
    _agent_conf
    _agent_logrotate
    _agent_units

    # Best effort: the bot only starts if Kuma has a Telegram notification to
    # copy credentials from. Everything else above works regardless.
    _agent_telegram_conf

    log_success "Action agent installed (socket: ${AGENT_SOCKET})"
}

# ── Accounts ────────────────────────────────────────────────────────────────
_agent_accounts() {
    getent group "$AGENT_GROUP" >/dev/null 2>&1 \
        || groupadd --system "$AGENT_GROUP"

    if ! getent passwd "$AGENT_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
            --home-dir /nonexistent --user-group "$AGENT_USER"
    fi
    usermod -aG "$AGENT_GROUP" "$AGENT_USER" 2>/dev/null || true
}

# ── Files ───────────────────────────────────────────────────────────────────
_agent_files() {
    local src="$1"

    mkdir -p "$AGENT_LIB_DIR" "$AGENT_STATE_DIR"
    # Modes follow who has to execute each one. corex_common holds no secrets
    # and both users import it. The bot's own script must be readable by
    # corex-bot, which 0750 root:root is not: the service crash-looped with
    # "can't open file: Permission denied" until this was owned by its group.
    install -m 0644 "${src}/corex_common.py" "${AGENT_LIB_DIR}/corex_common.py"
    # The dashboard's user store. Imported by the agent, which holds the only
    # privilege that can read /etc/corex/dashboard-users.json, and by the
    # root-only CLI behind `corex manage dashboard-user`. No secrets in the
    # module itself, so it matches corex_common's mode.
    install -m 0644 "${src}/corex_users.py"  "${AGENT_LIB_DIR}/corex_users.py"
    install -m 0644 "${src}/corex_metrics.py" "${AGENT_LIB_DIR}/corex_metrics.py"
    install -m 0750 "${src}/corex-usersctl.py"       /usr/local/bin/corex-usersctl
    install -m 0750 "${src}/corex-agent.py"          /usr/local/bin/corex-agent.py
    install -m 0750 "${src}/corex-telegram-setup.py" /usr/local/bin/corex-telegram-setup.py
    install -m 0750 -g "$AGENT_USER"  "${src}/corex-telegram.py" /usr/local/bin/corex-telegram.py
    install -m 0750 -g "$AGENT_GROUP" "${src}/corex-agentctl.py" /usr/local/bin/corex-agentctl

    chown "${AGENT_USER}:${AGENT_USER}" "$AGENT_STATE_DIR" 2>/dev/null || true
    chmod 0750 "$AGENT_STATE_DIR"

    # The bot cannot create its own log file under ProtectSystem=strict, so it
    # is created here with the right owner.
    touch /var/log/corex-agent.log /var/log/corex-telegram.log \
          /var/log/corex-dashboard-auth.log
    chmod 0640 /var/log/corex-agent.log /var/log/corex-telegram.log \
               /var/log/corex-dashboard-auth.log
    chown root:root      /var/log/corex-agent.log /var/log/corex-dashboard-auth.log
    chown "${AGENT_USER}:${AGENT_USER}" /var/log/corex-telegram.log 2>/dev/null || true

    # Generated once and kept. Regenerating it on every re-run would lock out
    # the dashboard container until it was restarted to re-read the file.
    if [[ ! -s "$AGENT_TOKEN_FILE" ]]; then
        ( umask 077; openssl rand -hex 32 > "$AGENT_TOKEN_FILE" ) \
            || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$AGENT_TOKEN_FILE"
    fi
    chmod 0640 "$AGENT_TOKEN_FILE"
    chown "root:${AGENT_GROUP}" "$AGENT_TOKEN_FILE" 2>/dev/null || true

    # /run/corex is created by tmpfiles rather than the unit's
    # RuntimeDirectory=. RuntimeDirectory deletes and recreates the directory
    # on every restart, which leaves the dashboard container holding a bind
    # mount of a deleted inode: restarting the agent would silently break the
    # dashboard's buttons until the container itself was restarted.
    cat > /etc/tmpfiles.d/corex-agent.conf << TMPEOF
d ${AGENT_RUN_DIR} 0750 root ${AGENT_GROUP} -
TMPEOF
    systemd-tmpfiles --create /etc/tmpfiles.d/corex-agent.conf 2>/dev/null || \
        { mkdir -p "$AGENT_RUN_DIR"; chgrp "$AGENT_GROUP" "$AGENT_RUN_DIR" 2>/dev/null || true; chmod 0750 "$AGENT_RUN_DIR"; }
}

# ── Config ──────────────────────────────────────────────────────────────────
_agent_conf() {
    local repo="${SCRIPT_DIR:-/opt/corex-pro}"
    cat > "$AGENT_CONF" << ACEOF
# CoreX action agent configuration.
COREX_REPO_ROOT=${repo}
COREX_MANAGE=${repo}/corex-manage.sh
AGENT_SOCKET=${AGENT_SOCKET}
AGENT_GROUP=${AGENT_GROUP}
AGENT_TOKEN_FILE=${AGENT_TOKEN_FILE}
AGENT_LOG=/var/log/corex-agent.log

# Send a Telegram message when a job finishes. Kuma only notifies on a state
# change, so a job that succeeds produces no Kuma event at all.
AGENT_NOTIFY=true

# Where to read Telegram credentials from if telegram.conf has none.
KUMA_DB=${DATA_ROOT:-/mnt/corex-data/service-data}/uptime-kuma/kuma.db
ACEOF
    chmod 0640 "$AGENT_CONF"
    chown "root:${AGENT_GROUP}" "$AGENT_CONF" 2>/dev/null || true
}

_agent_telegram_conf() {
    local db="${DATA_ROOT:-/mnt/corex-data/service-data}/uptime-kuma/kuma.db"
    if python3 /usr/local/bin/corex-telegram-setup.py "$db"; then
        chown "root:${AGENT_USER}" "$AGENT_TELEGRAM_CONF" 2>/dev/null || true
        chmod 0640 "$AGENT_TELEGRAM_CONF"
        systemctl enable corex-telegram.service 2>/dev/null || true
        systemctl restart corex-telegram.service 2>/dev/null || true
        log_success "Telegram control bot enabled"
    else
        log_info "No Telegram notification found in Uptime Kuma, so the control bot is idle."
        log_info "Configure one at https://status.${DOMAIN:-your-domain}, then run: corex manage agent setup"
    fi
}

_agent_logrotate() {
    cat > /etc/logrotate.d/corex-agent << LREOF
/var/log/corex-agent.log
/var/log/corex-telegram.log
/var/log/corex-dashboard-auth.log
{
    su root syslog
    weekly
    rotate 4
    maxsize 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LREOF
    chmod 0644 /etc/logrotate.d/corex-agent
}

# ── systemd units ───────────────────────────────────────────────────────────
_agent_units() {
    # The agent is root because that is the whole point: it does the work the
    # unprivileged clients cannot. It therefore gets no ProtectSystem, because
    # corex-manage legitimately writes /etc/corex/state.json and the compose
    # files under the data mount.
    cat > /etc/systemd/system/corex-agent.service << ASEOF
[Unit]
Description=CoreX action agent (privileged, unix socket)
After=docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/corex-agent.py
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
ASEOF

    # The bot is the opposite case. It parses untrusted input from the
    # internet, so it is confined as hard as it can be while still reaching
    # one socket and its own state file.
    cat > /etc/systemd/system/corex-telegram.service << TSEOF
[Unit]
Description=CoreX Telegram control bot
After=network-online.target corex-agent.service
Wants=network-online.target corex-agent.service

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_USER}
SupplementaryGroups=${AGENT_GROUP}
ExecStart=/usr/bin/python3 /usr/local/bin/corex-telegram.py
Restart=always
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${AGENT_STATE_DIR} /var/log/corex-telegram.log

[Install]
WantedBy=multi-user.target
TSEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable corex-agent.service 2>/dev/null || true
    # Restart, not just enable --now. `enable --now` leaves an already-running
    # unit alone, so re-running setup installed new code and kept executing the
    # old, which is the same trap as regenerating config only when it is
    # missing (gotcha #22).
    systemctl restart corex-agent.service 2>/dev/null || true
}

# ── Reporting ───────────────────────────────────────────────────────────────
agent_status() {
    systemctl is-active --quiet corex-agent.service 2>/dev/null || { echo "INACTIVE"; return 0; }
    [[ -S "$AGENT_SOCKET" ]] || { echo "NOSOCKET"; return 0; }
    echo "ACTIVE"
}

agent_telegram_status() {
    if ! grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$AGENT_TELEGRAM_CONF" 2>/dev/null; then
        echo "UNCONFIGURED"; return 0
    fi
    systemctl is-active --quiet corex-telegram.service 2>/dev/null \
        && echo "ACTIVE" || echo "INACTIVE"
}
