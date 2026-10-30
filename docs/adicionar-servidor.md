# Adicionar um servidor satélite

Exemplo: adicionar `srv-04`, usando a porta de túnel `19103`. Hub: `srv-monitor.example.com` (`192.0.2.10`).

## 0. Probe (somente leitura) no satélite

```bash
cat /etc/os-release
command -v docker || echo "sem docker"
ss -ltnp | grep -E ':(9100|13100)\b' || echo "portas livres"
csf -v 2>/dev/null; systemctl is-active csf lfd 2>/dev/null
# Conectividade de SAÍDA até a porta SSH do hub (faça isto primeiro):
nc -zv 192.0.2.10 22
```

Se o `nc` falhar e o CSF tiver política de saída restritiva, libere só o destino necessário (`agent/firewall/csf.allow.example`) e repita o teste antes de seguir.

## 1. No satélite: chave do túnel

```bash
install -d -m 700 /etc/monitoring-tunnel
ssh-keygen -t ed25519 -N '' -C 'tunnel-srv-04' -f /etc/monitoring-tunnel/id_ed25519
ssh-keyscan -p 22 192.0.2.10 > /etc/monitoring-tunnel/known_hosts
test -s /etc/monitoring-tunnel/known_hosts || echo "known_hosts vazio: verifique a saída do firewall"
```

## 2. No hub: usuário de túnel

```bash
useradd --system --create-home --shell /bin/true tunnel-srv-04
usermod -p '*' tunnel-srv-04
install -d -m 700 -o tunnel-srv-04 -g tunnel-srv-04 /home/tunnel-srv-04/.ssh
# authorized_keys com a chave PÚBLICA do satélite, prefixada por:
#   restrict,port-forwarding,permitopen="127.0.0.1:3100"
```

Adicione o bloco `Match User tunnel-srv-04` (modelo em `agent/ssh/sshd_config-tunnel.example`), depois:

```bash
sshd -t && systemctl reload sshd
```

A regra de firewall da faixa `19100-19110` já cobre a nova porta; não é preciso reiniciar CSF nem Docker.

## 3. No hub: alvo no Prometheus

```yaml
  - job_name: node-exporter-srv-04
    static_configs:
      - targets: ['172.19.0.1:19103']
        labels:
          instance: 'srv-04'
```

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

## 4. No satélite: agentes

1. Instale o binário do `node_exporter` (mesma versão do hub) em `/usr/local/bin/`, crie o usuário `node_exporter` e o diretório `/var/lib/node_exporter/textfile_collector`. Use `agent/systemd/node_exporter.service`.
2. Instale o Grafana Alloy pelo repositório oficial do seu sistema e copie `alloy/agent.alloy` para `/etc/alloy/config.alloy`, trocando `srv-01` por `srv-04` e ajustando a lista de domlogs (ou removendo o bloco).
3. Valide: `alloy fmt /etc/alloy/config.alloy`.
4. Copie `agent/systemd/monitoring-tunnel.service`, ajustando `TUNNEL_USER=tunnel-srv-04` e `REMOTE_PORT=19103`.

```bash
systemctl daemon-reload
systemctl enable --now node_exporter alloy monitoring-tunnel
systemctl is-active node_exporter alloy monitoring-tunnel
```

## 5. Verificação

No hub:

```bash
./scripts/healthcheck.sh
curl -s -G http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={host="srv-04"}' --data-urlencode 'limit=3'
```

Teste de resiliência no satélite:

```bash
systemctl kill monitoring-tunnel   # deve voltar sozinho em ~5 s
systemctl show monitoring-tunnel -p NRestarts
```

Confirme também que os serviços do próprio servidor (painel, web, e-mail) seguem ativos e que memória e disco não mudaram de forma perceptível.

## Acompanhamento nos primeiros dias

```bash
systemctl show node_exporter alloy monitoring-tunnel -p NRestarts
journalctl -u alloy --since "1 hour ago" --no-pager | grep -i error
```

Esperado: os três serviços `active`, `NRestarts` sem crescer, alvo `up` no Prometheus.

## Adicionar um domínio à coleta Web/HTTP

1. Acrescente as duas entradas (http + ssl) em `local.file_match "web_domlogs"` no Alloy do servidor.
2. Inclua o domínio em `/etc/alloy/domlogs.list` e rode `scripts/reapply-domlog-acl.sh` (e agende no cron).
3. `alloy fmt` + `systemctl restart alloy`.

O domínio aparece automaticamente na variável "Dominio" do dashboard "Logs e Eventos".
