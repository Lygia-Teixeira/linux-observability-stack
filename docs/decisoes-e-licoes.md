# Decisões e lições aprendidas

## Decisões

### 1. Nada exposto por padrão

Todas as portas do hub são publicadas em `127.0.0.1`. O acesso ao Grafana é por túnel SSH:

```bash
ssh -L 3000:localhost:3000 -p <porta-ssh> <usuario>@srv-monitor.example.com
# depois: http://localhost:3000
```

O hub também roda serviços de produção (painel de hospedagem, e-mail). Expor Prometheus, Loki ou o Alloy não traz benefício e abre APIs sem autenticação (`auth_enabled: false` no Loki, API HTTP do Prometheus).

### 2. Exposição do Grafana: só com controles

No ambiente original, o túnel deixou de ser prático para o dia a dia da equipe e o Grafana foi publicado em um subdomínio, atrás de proxy reverso Apache com TLS. Este repositório **não** faz isso por padrão, e a recomendação é preferir uma rede privada (VPN ou túnel tipo zero trust) quando possível. Se for publicar, o mínimo que se mostrou necessário:

- Proxy reverso com TLS; o Grafana continua em `127.0.0.1:3000`.
- Excluir a rota de validação ACME do proxy, senão a emissão do certificado falha (a requisição vai para o Grafana e volta a página de login):

  ```apache
  ProxyPreserveHost On
  ProxyPass /.well-known/acme-challenge/ !
  ProxyPass /api/live/ws ws://127.0.0.1:3000/api/live/ws
  ProxyPassReverse /api/live/ws ws://127.0.0.1:3000/api/live/ws
  ProxyPass / http://127.0.0.1:3000/
  ProxyPassReverse / http://127.0.0.1:3000/
  ```
- Renomear o usuário `admin` e usar senha forte; `GF_COOKIE_SECURE=true`.
- **Contas individuais** antes de divulgar a URL, em vez de uma conta compartilhada.
- Cadastro público e acesso anônimo desligados (já fixos no compose).
- Rotacionar qualquer credencial que tenha aparecido em texto claro (terminal, chat, leitura do `.env`), mesmo que não tenha sido salva em lugar nenhum.

### 3. Permissões no Grafana por pasta e Team

Por padrão, todo usuário novo entra na organização como Viewer (`auto_assign_org_role = Viewer`) e enxerga tudo. A organização adotada:

- Pastas por público (aqui: `infra` e `operacao`, criadas pelo provisionamento a partir das subpastas de `grafana/dashboards/`).
- Um Team por pasta, com permissão **View** na pasta correspondente.
- Remoção das linhas padrão "Editor pode editar" e "Viewer pode ver" de cada pasta, deixando só Admin + o Team.

**Armadilha encontrada:** depois de restringir as pastas, um usuário sem Team continuava vendo os dashboards. Dashboards têm **permissões próprias**, que se somam às da pasta; as linhas de função criadas antes da reorganização continuavam lá. É preciso limpar também a aba Permissões de cada dashboard e testar com um usuário sem Team.

**Viewer é suficiente para investigar alertas:** troca variáveis, período, zoom e exporta CSV de um painel. Não salva alterações nem usa o Explore (consulta ad-hoc), que exige Editor.

### 4. Alertas por e-mail via SMTP externo

Usar um SMTP externo com senha de aplicação evita alterar o MTA (Exim/Postfix) de qualquer servidor de produção. Credenciais só no `.env` (chmod 600).

### 5. Coleta de access logs opt-in

Coletar todos os domínios de todas as contas geraria volume muito alto e exigiria acesso amplo do usuário `alloy` aos logs de todos os clientes. A coleta é por domínio sob investigação, com ACL de leitura apenas nos dois arquivos daquele domínio.

### 6. Classificação na coleta, não no dashboard

O `detected_level` automático do Loki não marca bloqueios de firewall nem boa parte dos logs de autenticação como erro/aviso, e os painéis ficavam "Sem dados". A solução foi atribuir `categoria` no Alloy e usar filtros de texto explícitos nas queries.

## Ruído de alertas e calibração

- **Janela `for` é a principal defesa contra falso positivo.** Reiniciar o `node_exporter` zera os contadores de CPU e gera um pico artificial; com `for: 10m`, a regra "CPU alta" vai a Pending e volta sem disparar.
- **Limiares mantidos em 85%** após a calibração: CPU e memória ficaram com folga confortável em todos os servidores. O caso que se aproximou do limiar (disco durante uma migração) foi tratado na causa, não baixando ou subindo o limiar. Se for preciso aviso antecipado em um servidor específico, a opção discutida foi um limiar de atenção mais baixo (ex.: 80%) só para ele.
- **Memória usa `MemAvailable`**: picos de cache/buffer do Linux não representam pressão de memória.
- **Saltos de disco** quase sempre eram rotinas de backup do painel; o alerta de disco tem `for: 15m` e a descrição pede verificação antes de agir.
- **Não alertar cada ERROR individual.** Alertas baseados em log (rajadas de SSH falho, HTTP 5xx, ModSecurity acima do baseline, volume anômalo) ficaram fora do provisionamento até haver baseline suficiente. A tabela de anomalia (5 min vs média da última hora; verde < 2x, amarelo 2-4x, vermelho > 4x) é uma leitura pontual, não um alerta. Para virar alerta, precisa de regra com `for` para exigir persistência.
- **Um único emissor ruidoso distorce o contador da frota inteira.** Um serviço em loop de falha respondia pela grande maioria do contador "Erros" e mascarava erros reais em outros servidores. Opções: corrigir a causa, excluir só ele do contador global, ou aceitar e documentar.
- **Volume alto não é sinônimo de falso positivo.** Bloqueios de firewall em grande quantidade em todos os servidores expostos à internet são tráfego real de varredura bloqueado.

## Lições técnicas

1. **Dimensione Grafana e Loki com 1 GB desde o início.** Os problemas de OOM só apareceram a partir do quinto dia; teste por vários dias antes de considerar estável.
2. **Filtre cardinalidade na origem.** `session-*.scope` derruba o Loki por excesso de streams.
3. **Exclua containers legados da coleta** antes que virem ruído.
4. **Teste a saída do satélite antes de configurar o túnel** (`nc -zv`). Falhas silenciosas (como `ssh-keyscan` sem conseguir sair) geram erros em cascata difíceis de ler.
5. **`csf -r` apaga as regras do Docker.** Planeje a faixa de portas uma vez só.
6. **Conta "sem senha" ≠ conta bloqueada.** `!!` no shadow impede até login por chave; use `*`.
7. **Regex no Loki (RE2):** `5[0-9]{2}` combinado com aspas literais na mesma expressão retornou zero resultados; `5[0-9][0-9]` funcionou. Valide toda query contra dados reais antes de publicar o painel.
8. **Variável "All" no Loki:** forçar `allValue: .*` quebra as queries, porque o Loki exige ao menos um matcher que não aceite valor vazio. Deixe o Grafana expandir "All" para a lista real de valores.
9. **Rotação de log quebra ACL.** O arquivo novo não herda a ACL; mitigado por cron (`scripts/reapply-domlog-acl.sh`), não é um hook nativo de rotação.
10. **Valide a configuração do Alloy antes de reiniciar** (`alloy fmt`) e confirme o serviço ativo depois.
11. **Monitore o próprio armazenamento do Loki.** O volume cresceu de forma linear com o número de satélites e dobrou entre duas medições depois que a coleta de access logs entrou. Acompanhe antes de ampliar a coleta.
12. **Teste de resiliência faz parte do onboarding:** derrubar o túnel de propósito e ver a reconexão automática.
13. **Achados do monitoramento nem sempre são problema do monitoramento.** Muitos alarmes iniciais eram comportamento real dos servidores (backup, varredura de malware, aplicação com N+1). Investigar antes de filtrar.
