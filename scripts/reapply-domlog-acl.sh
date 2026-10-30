#!/usr/bin/env bash
# Reaplica a ACL de leitura do usuario "alloy" nos domlogs em coleta opt-in.
#
# A rotacao diaria de logs do cPanel recria os arquivos sem herdar a ACL e a
# coleta do dominio para silenciosamente. Este script e uma mitigacao via cron
# (nao e um hook nativo de rotacao).
#
# Cron sugerido:  */10 * * * * /usr/local/bin/reapply-domlog-acl.sh
#
# Lista de dominios: um por linha em /etc/alloy/domlogs.list

set -euo pipefail

LIST="${LIST:-/etc/alloy/domlogs.list}"
DOMLOG_DIR="${DOMLOG_DIR:-/etc/apache2/logs/domlogs}"

[[ -r "${LIST}" ]] || exit 0

while IFS= read -r dominio; do
  [[ -z "${dominio}" || "${dominio}" == \#* ]] && continue
  for f in "${DOMLOG_DIR}/${dominio}" "${DOMLOG_DIR}/${dominio}-ssl_log"; do
    [[ -e "${f}" ]] || continue
    if ! getfacl -p "${f}" 2>/dev/null | grep -q '^user:alloy:r'; then
      setfacl -m u:alloy:r "${f}"
    fi
  done
done < "${LIST}"
