# Rollout em fases

O ambiente foi implantado em uma frota de servidores Linux com cPanel/Apache em produção, um passo por vez, com período de observação entre cada passo. A regra geral: **nenhuma mudança na stack de monitoramento pode afetar os serviços que ela observa.**

## Fase 1 — Laboratório no próprio hub (12 dias)

**Objetivo:** responder se a stack, sozinha, causa impacto perceptível no servidor onde roda.

- Stack completa em Docker (`docker-compose.yml`), todas as portas em `127.0.0.1`, acesso por túnel SSH.
- Monitorando apenas o próprio hub.
- Planejado para 7 dias, estendido por mais 5 para aumentar a confiança antes de expandir.

**O que foi observado:** CPU, memória, disco e rede do host; crescimento do volume do Loki; reinícios dos 5 containers.

**Problemas encontrados e corrigidos:**

| Dia | Problema | Causa raiz | Correção |
|---|---|---|---|
| 1 | Logs de containers sem identificação | falta de relabel no Alloy | labels `container` e `container_id` |
| 1 | Alloy em loop de erro `maximum active stream limit exceeded` | cada login SSH cria uma unidade `session-*.scope` única | regra de descarte no relabel do journal |
| 3 | Ruído de containers de teste antigos | driver de log incompatível + backlog sendo reprocessado | containers excluídos da coleta |
| 5 | Grafana reiniciando repetidamente | OOM killer, limite de 256 MB | limite para 1 GB |
| 7 | Loki com memória em alta | limite de 512 MB sem folga após dias de índices | limite para 1 GB |

**Resultado:** zero reinícios não planejados após os ajustes, sem tendência de aumento de CPU/memória/disco do host, crescimento linear do armazenamento de logs. Nenhum problema atingiu os serviços de produção do servidor.

## Fase 2 — Expansão para satélites (modelo hub)

**Objetivo:** conectar os demais servidores sem replicar a stack.

- Um satélite por vez, cada um com alguns dias de acompanhamento antes do próximo.
- Satélites com sistemas operacionais diferentes (CentOS 7, Ubuntu 20.04/22.04/24.04, AlmaLinux 9), todos sem Docker e com CSF como firewall.
- Ao final: todos os servidores (hub + satélites) com alvos `up` no Prometheus e labels de host presentes no Loki.

**Procedimento consolidado** (detalhado em [adicionar-servidor.md](adicionar-servidor.md)):

1. Probe somente leitura do servidor (SO, Docker, portas livres, firewall, **conectividade de saída** até o hub).
2. Usuário de túnel restrito + chave dedicada + `Match User` no hub.
3. Job de scrape no `prometheus.yml` com a próxima porta livre da faixa.
4. `node_exporter` + Alloy nativos no satélite.
5. Serviço systemd do túnel com `Restart=always`.
6. Verificação: alvo `up`, label `host` no Loki, teste de resiliência (derrubar o túnel de propósito e ver a reconexão), e confirmação de que os serviços do servidor (cPanel, e-mail) seguem intactos.

**Surpresas que viraram item de checklist:**

- Conta de túnel criada "sem senha" ficou com `!!` no shadow: o PAM bloqueia o login mesmo por chave. Usar `*`.
- O CSF do hub bloqueou o scrape (política padrão de negar). Liberar só a subnet Docker para as portas do túnel.
- `csf -r` recarrega o iptables do zero e apaga as regras do Docker; foi preciso `systemctl restart docker`. A partir do segundo satélite a regra passou a ser uma **faixa** (19100-19110), evitando reiniciar firewall/Docker a cada novo servidor.
- Alguns satélites tinham CSF com política restritiva de **saída**: o túnel não saía e o `ssh-keyscan` falhou em silêncio, deixando o `known_hosts` vazio ("Host key verification failed"). Desde então o probe inclui `nc -zv <hub> <porta-ssh>` antes de qualquer configuração.
- Na sintaxe avançada do CSF, `s=`/`d=` valem para cada campo (porta e IP), não para a direção da regra.

**Achados sobre os servidores monitorados** (não eram problemas do monitoramento, mas apareceram graças a ele): um serviço em loop de falha gerando a maior parte do volume de log de um satélite, swap pequeno sempre cheio sem pressão real de memória, saltos de disco causados pela rotina de backup do painel, load alto por backup e varredura de malware concorrentes.

## Fase 3 — Dashboards e alertas

**Dashboard "Visão Geral"** (`grafana/dashboards/infra/visao-geral.json`): indicadores de servidores/online/atenção/crítico, tabela por servidor (status, CPU, memória, disco, load, uptime, licença do WAF) e histórico de CPU/memória (24h) e disco (7d).

**Alertas** (Grafana Unified Alerting, `grafana/provisioning/alerting/`): servidor offline, CPU, memória e disco. E-mail via SMTP externo para não mexer no MTA dos servidores de produção. Validado ponta a ponta parando o `node_exporter` de um satélite: o alerta disparou só para aquele `instance`, o e-mail chegou, e a resolução também foi notificada após religar o agente.

**Dashboard "Logs e Eventos"** (`grafana/dashboards/operacao/logs-eventos.json`): filtros por servidor/categoria/serviço/nível/busca, contadores, top ofensores, tabela de anomalia de volume, seção de segurança e seção Web/HTTP.

**Label `categoria`** criado no Alloy de todos os servidores.

**Seção Web/HTTP** nasceu de um caso real: agentes de inventário de uma rede cliente batiam a cada 1-2 segundos em um endpoint que respondia HTTP 500 na grande maioria das requisições. A coleta de access log foi desenhada como opt-in e genérica (lista no Alloy + ACL por arquivo), para que o próximo domínio não exija editar o dashboard.

**Métrica customizada** via textfile collector (licença do WAF comercial), que já na primeira leitura revelou uma licença cancelada em um dos servidores.

**Controle de acesso** e **exposição do Grafana**: ver [decisoes-e-licoes.md](decisoes-e-licoes.md).

## Fase 4 — Calibração

Ciclo de uma semana com foco em quatro pontos, sempre medindo direto no Loki/Prometheus em vez de confiar só no dashboard:

| Ponto | Resultado |
|---|---|
| Reduzir logs desnecessários | 3 fontes de ruído filtradas na origem (WARN de rotina de uma aplicação Java, limpeza de shim do containerd, autodiagnóstico interno do Loki). Antes de cada filtro, confirmado no histórico que nenhuma linha de erro real seria perdida. |
| Corrigir classificações | Nenhuma correção necessária; todas as categorias apareceram com mais tempo de coleta. |
| Ajustar limiares | CPU/memória com folga confortável em todos os servidores; 85% mantido. Um servidor chegou perto do limiar de disco durante uma migração, e o caso se resolveu com aumento de disco, sem mudar o limiar. |
| Falsos positivos | Aplicação despejando WARN de rotina: corrigido. Serviço em loop de falha dominando o contador "Erros" da frota: mantido como decisão consciente, documentado. Bloqueios de firewall em volume alto: **não** é falso positivo, é varredura real bloqueada. |

Incidentes reais detectados no período: picos de CPU por padrão N+1 em uma aplicação interna, rajada de requisições de um único IP com User-Agents rotativos contra um site em PHP-CGI, e o endpoint com erro 5xx citado acima.

Também nesta fase: configuração versionada em git com varredura de segredos antes de cada push, e scripts de onboarding de satélite e de domínio Web/HTTP.
