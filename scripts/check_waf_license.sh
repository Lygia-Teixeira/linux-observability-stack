#!/usr/bin/env bash
# Exemplo de metrica customizada via textfile collector do node_exporter.
#
# Consulta o status de licenca de um WAF comercial e grava waf_license_valid
# (1 = valida, 0 = invalida). O node_exporter expoe o arquivo junto com as
# demais metricas, sem precisar de um exporter novo. O dashboard "Visao Geral"
# mostra a coluna "Licenca WAF".
#
# Cron sugerido:  */30 * * * * /usr/local/bin/check_waf_license.sh
#
# Satelite (node_exporter nativo): OUTPUT_DIR=/var/lib/node_exporter/textfile_collector
# Hub (node_exporter em container): OUTPUT_DIR=<repo>/node-exporter-textfile

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/var/lib/node_exporter/textfile_collector}"
OUTPUT_FILE="${OUTPUT_DIR}/waf_license.prom"
TMP_FILE="${OUTPUT_FILE}.$$"

# Ajuste para o CLI do seu produto. Deve imprimir algo como "License is valid".
LICENSE_CMD="${LICENSE_CMD:-/opt/waf/bin/waf-cli license --status}"
VALID_PATTERN="${VALID_PATTERN:-License is valid}"

STATUS="$(${LICENSE_CMD} 2>&1 || true)"

if grep -q "${VALID_PATTERN}" <<<"${STATUS}"; then
  VALID=1
else
  VALID=0
fi

cat > "${TMP_FILE}" <<EOF
# HELP waf_license_valid Whether the WAF license is valid (1) or not (0)
# TYPE waf_license_valid gauge
waf_license_valid ${VALID}
EOF

# Escrita atomica: o node_exporter nunca le um arquivo pela metade.
mv "${TMP_FILE}" "${OUTPUT_FILE}"
