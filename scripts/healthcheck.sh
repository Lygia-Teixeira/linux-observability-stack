#!/usr/bin/env bash
# Verificacao rapida do hub. Rode no srv-monitor apos "docker compose up -d".
set -uo pipefail

ok()   { printf '  [ok]   %s\n' "$1"; }
fail() { printf '  [FALHA] %s\n' "$1"; }

echo "Containers:"
docker compose ps --format 'table {{.Name}}\t{{.Status}}'

echo "Endpoints:"
curl -fs http://127.0.0.1:9090/-/healthy >/dev/null && ok "Prometheus" || fail "Prometheus"
curl -fs http://127.0.0.1:3100/ready     >/dev/null && ok "Loki"       || fail "Loki"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/health)
[[ "${code}" == "200" ]] && ok "Grafana" || fail "Grafana (HTTP ${code})"

echo "Alvos do Prometheus (health):"
curl -fs http://127.0.0.1:9090/api/v1/targets \
  | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("  %-14s %s" % (t["labels"].get("instance", "?"), t["health"]))
'

echo "Hosts com logs no Loki:"
curl -fs http://127.0.0.1:3100/loki/api/v1/label/host/values \
  | python3 -c 'import json,sys; print("  " + ", ".join(json.load(sys.stdin).get("data", [])))'
