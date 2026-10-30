#!/usr/bin/env bash
# Baixa o dashboard comunitario "Node Exporter Full" (grafana.com, ID 1860).
# Nao e versionado neste repositorio (conteudo de terceiros; ver .gitignore).
# Revise o JSON antes de usar.

set -euo pipefail

REVISION="${REVISION:-37}"
DEST="$(dirname "$0")/../grafana/dashboards/infra/node-exporter-full.json"

curl -fsSL -o "${DEST}" \
  "https://grafana.com/api/dashboards/1860/revisions/${REVISION}/download"

# O JSON publicado usa ${DS_PROMETHEUS}; aponta para o datasource provisionado.
sed -i 's/\${DS_PROMETHEUS}/prometheus/g' "${DEST}"

echo "Salvo em ${DEST}"
