# Painéis e queries

Referência das queries usadas nos dashboards provisionados. Os JSON estão em `grafana/dashboards/`.

## Visão Geral — Todos os Servidores (`infra/visao-geral.json`)

Período global "últimos 5 minutos" (tabela e indicadores usam consultas instantâneas); os gráficos fixam o próprio período via `timeFrom`.

### Base

| Métrica | PromQL |
|---|---|
| Status | `max by(instance) (up{job=~"node-exporter.*"})` |
| CPU % | `100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| Memória % | `100 * (1 - (avg by(instance) (node_memory_MemAvailable_bytes) / avg by(instance) (node_memory_MemTotal_bytes)))` |
| Disco % (/) | `100 - (avg by(instance) (node_filesystem_avail_bytes{mountpoint="/"}) / avg by(instance) (node_filesystem_size_bytes{mountpoint="/"}) * 100)` |
| Load (1m) | `avg by(instance) (node_load1)` |
| Uptime | `avg by(instance) (time() - node_boot_time_seconds)` (unidade `dtdurations`) |
| Licença WAF | `avg by(instance) (waf_license_valid)` (textfile collector) |

### Indicadores

| Indicador | Query |
|---|---|
| Servidores | `count(up{job=~"node-exporter.*"})` |
| Online | `count(up{job=~"node-exporter.*"} == 1)` |
| Crítico | servidores offline **ou** com algum recurso > 85% |
| Atenção | servidores com algum recurso entre 70% e 85%, `unless` os críticos |

"Crítico" e "Atenção" combinam as três métricas com `or on(instance)` e deduplicam com `count by(instance)`, para não contar o mesmo servidor duas vezes. Os dois têm `noValue: "0"` para mostrar zero em vez de "Sem dados".

### Tabela

Sete queries instantâneas em formato tabela, unidas com a transformação `joinByField` (campo `instance`) e `organize` para renomear colunas e esconder campos técnicos (`Time`, `job`, `__name__` e as variantes numeradas que o join gera). Cores: verde < 70%, amarelo 70-85%, vermelho > 85%.

### Histórico

CPU (24h), Memória (24h), Disco (7d), uma série por `instance`.

## Logs e Eventos (`operacao/logs-eventos.json`)

Variáveis: `host` (Servidor), `categoria`, `unit` (Serviço), `nivel` (Tudo / Atenção / Erro / Aviso / Bloqueio / Falha de login), `busca` (texto livre), `dominio`. Período padrão: últimas 6h.

Seletor base:

```logql
{host=~"$host", categoria=~"$categoria", unit=~"$unit"} |~ "$nivel" |~ "(?i)$busca"
```

| Painel | LogQL (resumo) |
|---|---|
| Logs | `sum(count_over_time(<base> [$__range]))` |
| Erros | `<base> \|~ "(?i)error\|critical\|fatal\|failed"` |
| Warnings | `<base> \|~ "(?i)warn"` |
| Bloqueios | `<base> \|~ "(?i)blocked\|denied"` (qualquer origem) |
| Top serviços / servidores | `topk(10, sum by(unit) (count_over_time(... \|~ "(?i)error\|warning\|critical\|fatal" [$__range])))` |
| Anomalia de volume | `sum by(host) (count_over_time({host=~"$host"}[5m])) / (sum by(host) (count_over_time({host=~"$host"}[1h])) / 12)` — verde < 2x, amarelo 2-4x, vermelho > 4x |

### Segurança / Acessos

| Painel | LogQL |
|---|---|
| SSH falhos | `{categoria="autenticacao"} \|~ "(?i)failed password\|invalid user"` |
| Firewall (IPDB / lfd) | `{categoria="firewall"} \|~ "(?i)ipdb blocked\|lfd"` |
| ModSecurity | `{host=~"$host"} \|~ "(?i)modsecurity\|mod_security"` |
| Autenticações | `{categoria="autenticacao"} \|~ "(?i)accepted\|session opened\|login"` |

"Firewall" conta especificamente bloqueios do firewall; "Bloqueios" (resumo) é mais amplo.

### Web / HTTP

Baseado nos access logs coletados por domínio (`categoria="web"`, label `dominio`).

| Painel | LogQL |
|---|---|
| Requisições HTTP | `sum(count_over_time({categoria="web", dominio=~"$dominio"} [$__range]))` |
| Erros 5xx | ``{categoria="web", ...} \|~ `" 5[0-9][0-9] ` `` |
| Erros 4xx | ``{categoria="web", ...} \|~ `" 4[0-9][0-9] ` `` |
| Domínios monitorados | `count(sum by(dominio) (count_over_time({categoria="web"} [$__range])))` |
| Volume por domínio | `sum by(dominio) (count_over_time({categoria="web"} [$__auto]))` |
| Top domínios com 5xx | `topk(10, sum by(dominio) (count_over_time(... 5xx ... [$__range])))` |

O código de status é reconhecido pela posição na linha do log (após a aspa que fecha a requisição), não por palavras como "error". Evite `5[0-9]{2}`: ver lição sobre RE2 em [decisoes-e-licoes.md](decisoes-e-licoes.md).

## Consultas úteis no Explore

```logql
# volume de logs por servidor
sum by (host) (count_over_time({host=~".+"}[1h]))

# logs de um servidor
{host="srv-01"}
```

## Alertas baseados em log (não provisionados)

Candidatos para uma segunda rodada, depois de acumular baseline. Todos devem ter `for` para exigir persistência:

```logql
# rajada de falhas de SSH por servidor
sum by(host) (count_over_time({categoria="autenticacao"} |~ "(?i)failed password|invalid user" [5m]))

# taxa de 5xx por domínio
sum by(dominio) (count_over_time({categoria="web"} |~ `" 5[0-9][0-9] ` [5m]))
  / sum by(dominio) (count_over_time({categoria="web"} [5m]))
```
