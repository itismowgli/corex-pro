#!/bin/bash
# lib/services/monitoring.sh — CoreX Pro v2
# Monitoring Stack — Uptime Kuma + Grafana + Prometheus + Node Exporter + cAdvisor
#
# CRITICAL NOTES:
#   - Prometheus data dir MUST be owned by uid 65534 (nobody:nogroup)
#   - Grafana data dir MUST be owned by uid 472 (grafana user in container)
#   - prometheus.yml is a file mount (not directory) — create file first
#   - monitoring-net is separate from proxy-net (Prometheus/exporters not exposed)

# ── Metadata ──────────────────────────────────────────────────────────────────
SERVICE_NAME="monitoring"
SERVICE_LABEL="Monitoring Stack — Uptime Kuma + Grafana + Prometheus"
SERVICE_CATEGORY="monitoring"
SERVICE_REQUIRED=false
SERVICE_NEEDS_DOMAIN=true
SERVICE_NEEDS_EMAIL=false
SERVICE_RAM_MB=1024
SERVICE_DISK_GB=5
# UFW rules this service opens, as full `ufw allow` specs. cmd_remove
# revokes them, because leaving a port open with nothing behind it is all
# of the exposure and none of the service.
SERVICE_FIREWALL_SPECS=("3001/tcp" "3002/tcp" "9090/tcp")
SERVICE_DESCRIPTION="Complete observability stack. Uptime Kuma for status pages, Grafana for dashboards, Prometheus for metrics collection. Monitor all services from one place."

# Uptime Kuma check, seeded by lib/kuma.sh so it is recreated on a fresh
# install rather than living only in Kuma's database. Tab separated:
# name, url, accepted status codes. The name is the key, so changing it
# creates a second monitor and orphans the first.
SERVICE_MONITORS="Grafana	https://grafana.${DOMAIN:-}	[\"200-299\",\"302\"]
Uptime Kuma	https://status.${DOMAIN:-}	[\"200-299\",\"302\"]"

# ── Functions ─────────────────────────────────────────────────────────────────

monitoring_dirs() {
    mkdir -p "${DOCKER_ROOT}/monitoring"
    mkdir -p "${DOCKER_ROOT}/monitoring/grafana/provisioning/datasources"
    mkdir -p "${DOCKER_ROOT}/monitoring/grafana/provisioning/dashboards"
    mkdir -p "${DOCKER_ROOT}/monitoring/grafana/dashboards"
    mkdir -p "${DATA_ROOT}/uptime-kuma" "${DATA_ROOT}/grafana" "${DATA_ROOT}/prometheus"
    chown -R 1000:1000 "${DATA_ROOT}/uptime-kuma"
    chown -R 472:472 "${DATA_ROOT}/grafana"         # Grafana runs as uid 472
    chown -R 65534:65534 "${DATA_ROOT}/prometheus"  # Prometheus runs as nobody (65534)
}

monitoring_firewall() {
    ufw allow 3001/tcp comment 'Uptime Kuma Status Page' 2>/dev/null || true
    ufw allow 3002/tcp comment 'Grafana Dashboards'      2>/dev/null || true
    ufw allow 9090/tcp comment 'Prometheus (LAN only)'   2>/dev/null || true
}


# Grafana, with something in it.
#
# Without this the stack collects metrics into a store nothing displays: a
# fresh Grafana has no datasource and no dashboards, so the first thing it
# shows anyone is an empty home page and a form asking for a database URL.
# Four containers were running to fill a picture nobody could see, which is
# the entire reason this stack was switched off as "not in use".
#
# Regenerated unconditionally on every deploy and repair rather than written
# only when absent, for the reason in gotcha #22: these are generated files,
# not user state. A dashboard someone edits in the browser is saved by Grafana
# into its own database under a different id, so editing is not lost.
# The dashboard, pinned to the datasource above by uid rather than by name, so
# renaming the datasource in the UI cannot leave every panel querying nothing.
#
# It plots every hwmon sensor rather than guessing which chip is the CPU: on
# this box that is a Ryzen k10temp reading alongside five NVMe sensors, and the
# PCI address in the chip label is hardware specific, so picking one by name
# would draw an empty panel on anyone else's machine. Thresholds sit at the
# same 80C and 85C the thermal guardian uses, so the chart and the thing that
# shuts containers down agree about what "hot" means.
_monitoring_write_host_dashboard() {
    cat > "$1" << 'GDASHEOF'
{
  "uid": "corex-host",
  "title": "CoreX host and containers",
  "tags": [
    "corex"
  ],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "refresh": "1m",
  "time": {
    "from": "now-24h",
    "to": "now"
  },
  "panels": [
    {
      "type": "timeseries",
      "title": "Temperature, every sensor",
      "gridPos": {
        "h": 9,
        "w": 24,
        "x": 0,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 4,
            "showPoints": "never",
            "spanNulls": true,
            "thresholdsStyle": {
              "mode": "dashed"
            }
          },
          "unit": "celsius",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "#d9a24a",
                "value": 80
              },
              {
                "color": "red",
                "value": 85
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "node_hwmon_temp_celsius",
          "legendFormat": "{{chip}} {{sensor}}",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "CPU used",
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 9
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 14,
            "showPoints": "never",
            "spanNulls": true
          },
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[$__rate_interval])) * 100)",
          "legendFormat": "busy",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Load average",
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 9
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 8,
            "showPoints": "never",
            "spanNulls": true
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "node_load1",
          "legendFormat": "1 min",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        },
        {
          "expr": "node_load5",
          "legendFormat": "5 min",
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        },
        {
          "expr": "node_load15",
          "legendFormat": "15 min",
          "refId": "C",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Memory in use",
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 17
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 10,
            "showPoints": "never",
            "spanNulls": true
          },
          "unit": "bytes",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes",
          "legendFormat": "used",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        },
        {
          "expr": "node_memory_MemTotal_bytes",
          "legendFormat": "total",
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        },
        {
          "expr": "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes",
          "legendFormat": "swap",
          "refId": "C",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Disk space used",
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 17
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 8,
            "showPoints": "never",
            "spanNulls": true,
            "thresholdsStyle": {
              "mode": "dashed"
            }
          },
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "#d9a24a",
                "value": 80
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "100 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay|squashfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|squashfs\"} * 100)",
          "legendFormat": "{{mountpoint}}",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "CPU by container",
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 0,
        "y": 25
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 8,
            "showPoints": "never",
            "spanNulls": true
          },
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "topk(10, sum(rate(container_cpu_usage_seconds_total{name!=\"\"}[$__rate_interval])) by (name)) * 100",
          "legendFormat": "{{name}}",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Memory by container",
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 12,
        "y": 25
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 8,
            "showPoints": "never",
            "spanNulls": true
          },
          "unit": "bytes",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "topk(10, container_memory_working_set_bytes{name!=\"\"})",
          "legendFormat": "{{name}}",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Network",
      "gridPos": {
        "h": 8,
        "w": 24,
        "x": 0,
        "y": 34
      },
      "datasource": {
        "type": "prometheus",
        "uid": "corex-prom"
      },
      "fieldConfig": {
        "defaults": {
          "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 8,
            "showPoints": "never",
            "spanNulls": true
          },
          "unit": "Bps",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom",
          "calcs": [
            "lastNotNull",
            "max"
          ]
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "expr": "rate(node_network_receive_bytes_total{device!~\"lo|veth.*|br-.*|docker.*\"}[$__rate_interval])",
          "legendFormat": "in {{device}}",
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        },
        {
          "expr": "rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|br-.*|docker.*\"}[$__rate_interval])",
          "legendFormat": "out {{device}}",
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "corex-prom"
          }
        }
      ]
    }
  ]
}
GDASHEOF
}

_monitoring_write_grafana_provisioning() {
    local dir="$1"

    cat > "${dir}/grafana/provisioning/datasources/prometheus.yml" << 'GDSEOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: corex-prom
    type: prometheus
    access: proxy
    # The container name on monitoring-net. Not localhost: Grafana and
    # Prometheus are different containers.
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 30s
GDSEOF

    cat > "${dir}/grafana/provisioning/dashboards/corex.yml" << 'GPEOF'
apiVersion: 1
providers:
  - name: CoreX
    orgId: 1
    folder: CoreX
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
      foldersFromFilesStructure: false
GPEOF

    _monitoring_write_host_dashboard "${dir}/grafana/dashboards/corex-host.json"
    chown -R 472:472 "${dir}/grafana" 2>/dev/null || true
}

monitoring_deploy() {
    monitoring_dirs
    local dir="${DOCKER_ROOT}/monitoring"

    # Prometheus scrape config
    cat > "${dir}/prometheus.yml" << PEOF
global:
  scrape_interval: 30s

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100"]
  - job_name: cadvisor
    # cAdvisor enumerates every container on each scrape, so it is slower than
    # the 10s default even with the filesystem walks switched off. A timeout
    # shorter than the target's honest response time turns the whole job into
    # "context deadline exceeded" forever, with no other symptom.
    scrape_timeout: 20s
    static_configs:
      - targets: ["cadvisor:8080"]
PEOF

    _monitoring_write_grafana_provisioning "$dir"

    # Prometheus disk space alerts
    cat > "${dir}/alerts.yml" << 'ALEOF'
groups:
  - name: disk_alerts
    rules:
      - alert: SSDNearlyFull
        expr: >
          (node_filesystem_avail_bytes{mountpoint="/mnt/corex-data"} /
           node_filesystem_size_bytes{mountpoint="/mnt/corex-data"}) < 0.15
        for: 5m
        annotations:
          summary: "SSD < 15% free — run: corex manage cleanup"
      - alert: OSDiskNearlyFull
        expr: >
          (node_filesystem_avail_bytes{mountpoint="/"} /
           node_filesystem_size_bytes{mountpoint="/"}) < 0.10
        for: 5m
        annotations:
          summary: "OS disk < 10% free — check /var/lib/docker and container logs"
ALEOF

    # Grafana behind the shared login, when Authelia is installed and lists
    # it. Only grafana: Uptime Kuma has its own login and is the page you open
    # to find out why something is down, so it stays reachable on its own.
    local sso_label=""
    declare -f sso_label_for >/dev/null 2>&1 && sso_label="$(sso_label_for grafana)"

    cat > "${dir}/docker-compose.yml" << DCEOF
services:
  uptime-kuma:
    # Pinned, and not to :latest. That tag was last built in October 2025 and
    # is frozen on the 1.x line: upstream ships the current release as :2 and
    # :2.5.3, so a box tracking :latest sat ten months behind while every
    # `corex manage update` reported success. A moving tag that stops moving is
    # the inverse of gotcha #19 and just as silent.
    image: louislam/uptime-kuma:2.5.3
    container_name: uptime-kuma
    restart: unless-stopped
    ports: ["3001:3001"]
    volumes:
      - ${DATA_ROOT}/uptime-kuma:/app/data
    networks: [proxy-net, monitoring-net]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources:
        limits:
          # Uptime Kuma is Node, and 2.x is heavier than the 1.x line this
          # upgraded from. 256m leaves it a ~128MB heap, which is the shape of
          # failure that crash-looped n8n.
          memory: 512m
          cpus: "0.5"
        reservations:
          memory: 64m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.uptime.rule=Host(\`status.${DOMAIN}\`)"
      - "traefik.http.routers.uptime.entrypoints=websecure"
      - "traefik.http.routers.uptime.tls.certresolver=myresolver"
      - "traefik.http.services.uptime.loadbalancer.server.port=3001"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports: ["9090:9090"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./alerts.yml:/etc/prometheus/alerts.yml:ro
      - ${DATA_ROOT}/prometheus:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      # Time alone lets a busy month fill the disk, and the disk filling is
      # what stops the services. Whichever limit is reached first wins.
      - "--storage.tsdb.retention.time=30d"
      - "--storage.tsdb.retention.size=8GB"
      - "--web.enable-lifecycle"
    networks: [monitoring-net]
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "0.5"
        reservations:
          memory: 128m

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports: ["3002:3000"]
    volumes:
      - ${DATA_ROOT}/grafana:/var/lib/grafana
      # Read-only: these are generated on every repair, and Grafana writing
      # back into them would be overwritten without warning. Edits made in the
      # browser are saved to Grafana's own database instead, which survives.
      - ${DOCKER_ROOT}/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - ${DOCKER_ROOT}/monitoring/grafana/dashboards:/etc/grafana/dashboards:ro
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASS}"
      GF_SERVER_ROOT_URL: "https://grafana.${DOMAIN}"
    networks: [proxy-net, monitoring-net]
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "0.5"
        reservations:
          memory: 128m
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(\`grafana.${DOMAIN}\`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls.certresolver=myresolver"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"
${sso_label}

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command: ["--path.procfs=/host/proc", "--path.sysfs=/host/sys", "--path.rootfs=/rootfs"]
    networks: [monitoring-net]
    deploy:
      resources:
        limits:
          memory: 128m
          cpus: "0.25"
        reservations:
          memory: 32m

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    # Measured on this hardware before these flags: one scrape took 5m44s and
    # Prometheus gave up on every one of them, so cAdvisor ran permanently and
    # delivered nothing. The cost is per-container filesystem walks, which
    # cAdvisor logs itself: "disk usage and inodes count on following dirs took
    # 51.9s" for a single container, repeated across all of them. On a box that
    # thermal trips, that is a lot of disk and CPU for a number `docker system
    # df` already answers.
    command:
      # The expensive metrics are the filesystem ones. Everything else cAdvisor
      # collects is cheap and is the reason it is here.
      - --disable_metrics=disk,diskIO,tcp,udp,advtcp,sched,process,hugetlb,referenced_memory,cpu_topology,resctrl,memory_numa
      # Only containers, not every cgroup on the host. node-exporter covers the
      # host and does it far more cheaply.
      - --docker_only=true
      # Match the scrape interval. Housekeeping faster than the scrape is work
      # nobody reads.
      - --housekeeping_interval=30s
      - --store_container_labels=false
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
    networks: [monitoring-net]
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.25"
        reservations:
          memory: 64m

networks:
  proxy-net: { external: true }
  monitoring-net: { external: true }
DCEOF

    compose_up_enabled monitoring "${dir}/docker-compose.yml" \
        || log_warning "Monitoring stack may not have fully started — check: docker ps"
    state_service_installed "monitoring"
    log_success "Monitoring deployed (Kuma:3001, Grafana:3002, Prometheus:9090)"
}

monitoring_destroy() {
    local dir="${DOCKER_ROOT}/monitoring"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        docker compose -f "${dir}/docker-compose.yml" down
    state_service_removed "monitoring"
}

monitoring_status() {
    # Judge only the components that are meant to be running. Checking Grafana
    # unconditionally reported the module UNHEALTHY forever once Grafana was
    # deliberately disabled, so doctor kept flagging a fault that was a
    # choice.
    local required=() c
    for c in uptime-kuma grafana; do
        if declare -f state_component_is_enabled >/dev/null 2>&1; then
            state_component_is_enabled monitoring "$c" || continue
        fi
        required+=("$c")
    done

    # Everything disabled is a coherent state, not a failure.
    if [[ ${#required[@]} -eq 0 ]]; then
        container_exists "uptime-kuma" && echo "HEALTHY" || echo "MISSING"
        return 0
    fi

    for c in "${required[@]}"; do
        if ! container_running "$c"; then
            container_exists "$c" && { echo "UNHEALTHY"; return 0; }
            echo "MISSING"; return 0
        fi
    done
    echo "HEALTHY"
}

monitoring_repair() {
    # Regenerate the compose file first. Without this, repair recreated the
    # container from a compose file that could be months old, so CoreX fixes
    # to env vars, resource limits, security_opt, published ports or Traefik
    # labels never reached an existing install. monitoring_deploy is idempotent
    # by design (see CLAUDE.md "Idempotency pattern"), so calling it here is
    # safe and is what makes `corex doctor` able to deliver fixes at all.
    monitoring_deploy
    local dir="${DOCKER_ROOT}/monitoring"
    [[ -f "${dir}/docker-compose.yml" ]] && \
        compose_up_enabled monitoring "${dir}/docker-compose.yml" --force-recreate
}

monitoring_credentials() {
    echo "Uptime Kuma: https://status.${DOMAIN} (create admin on first visit)"
    echo "Grafana: https://grafana.${DOMAIN}"
    echo "  Username: admin"
    echo "  Password: ${GRAFANA_ADMIN_PASS}"
}
