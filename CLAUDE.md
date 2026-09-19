# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Projeto SN-2026 — Pipeline SIROS/ANAC + Supabase + GitHub Pages

Responda sempre em português do Brasil (pt-BR), com linguagem clara e objetiva.
Comentários no código devem estar em português.

## O que é
Painel de voos. Um workflow do GitHub Actions busca os voos do dia na API SIROS
(ANAC), grava no Supabase (PostgreSQL) e o `index.html`, publicado no GitHub
Pages, lê os dados direto do Supabase. Um segundo workflow importa, todo mês, o
histórico VRA da ANAC.

## Stack
- Python 3.12 (`requests`, `supabase`) nos scripts
- GitHub Actions (agendado + `workflow_dispatch`) e GitHub Pages
- Supabase: PostgreSQL com RLS, API REST pública somente para leitura
- Front-end: HTML + JavaScript puro em um único `index.html`

## Estrutura
- `scripts/fetch_flights.py` — SIROS → tabela `voos` (upsert em lotes de 500)
- `scripts/fetch_historico_anac.py` — VRA/ANAC → tabela `historico_vra`
- `sql/setup.sql` — tabelas, constraints, RLS, policies e GRANTs
- `data/airports.json` — cadastro de aeroportos usado pelo painel
- `.github/workflows/update-flights.yml` — pipeline diário
- `.github/workflows/importar-historico.yml` — importação mensal do VRA

## Arquitetura (o que exige ler vários arquivos)
- **Sem build, sem testes, sem linter, sem `requirements.txt`.** As dependências
  são instaladas direto no workflow (`pip install requests supabase`).
- Os scripts são lineares: rodam tudo no nível do módulo, sem `main()`, e já
  saem com `sys.exit(1)` na importação se faltar `SUPABASE_URL`/`SUPABASE_SERVICE_KEY`.
  Por isso não dá para importá-los para testar funções soltas.
- **A chave de deduplicação vive em 3 lugares e precisa ser idêntica:**
  `CHAVE_UNICA` no script, a string `on_conflict` do `upsert` e a `UNIQUE` em
  `sql/setup.sql`. Ao mudar uma, mude as três (vale para `voos` e `historico_vra`).
- Códigos de saída do `fetch_flights.py`: sem voos na API → `exit 0` (grava
  `sem_dados`); qualquer lote com erro → `exit 1` (`erro_parcial`/`erro_critico`),
  para o GitHub Actions marcar o run como falha.
- Só `fetch_flights.py` grava em `execucoes` (alimenta a aba Pipeline e o card
  "última atualização"). `fetch_historico_anac.py` não grava lá; escreve o resumo
  em `GITHUB_STEP_SUMMARY`.
- O painel lê `voos`, `historico_vra` e `execucoes` via REST (`sbFetch`). A
  tabela `aeroportos` **não é usada** pelo front: os selects estado → município →
  aeroporto vêm de `data/airports.json` (campos `icao, name, city, state,
  state_code`, em inglês/sem relação com as colunas `nome/cidade/estado` da tabela).
- Limites silenciosos no front: `voos` traz no máximo 500 linhas por
  chegadas/partidas e `historico_vra` no máximo 1000; acima disso a tela trunca
  sem avisar.
- `voos.data_referencia` é a data de hoje em BRT; `historico_vra.dt_referencia`
  é a data da partida prevista (o VRA não tem data de referência).
- Crons dos workflows estão em UTC: `0 9,12,15,21` = 06h/09h/12h/18h BRT; VRA
  no dia 3 às 09h UTC (mês anterior por padrão).
- `sql/setup.sql` foi **reconstruído** a partir do código, não é o original do
  professor. Se houver divergência, o banco real no Supabase é a fonte da verdade.
- URL e chave `anon` do Supabase estão fixas nas linhas iniciais do `<script>`
  do `index.html` (a `anon` é pública por design).

## Variáveis e segredos
| Nome | Tipo no GitHub | Uso |
|---|---|---|
| `SUPABASE_URL` | Secret | URL do projeto Supabase |
| `SUPABASE_SERVICE_KEY` | Secret | chave `service_role`, só os scripts usam |
| `AIRPORTS` | Variable | ICAOs separados por vírgula |
| `ANO_MES` | input do workflow | período do VRA, formato AAAA-MM |

## Restrições (não quebrar)
- NUNCA colocar a chave `service_role` em arquivo, commit, print ou mensagem.
  Ela vive só no GitHub Secret.
- O `index.html` usa apenas a chave `anon` (pública). RLS + policies garantem
  leitura pública e escrita apenas via `service_role`.
- Todo valor vindo do banco que entra em `innerHTML` deve passar por `escapeHtml`.
- Alterações pequenas e cirúrgicas: não reescrever arquivo inteiro sem pedido.
- Horários no painel em BRT (UTC-3); a API SIROS entrega UTC.
- Upsert precisa de `deduplicar` antes do envio (o Supabase falha com chaves
  repetidas no mesmo lote).
- Não fazer push no `main` sem aprovação explícita da Ana.

## Notas do VRA (arquivo real da ANAC)
- URL: `.../Voo Regular Ativo (VRA)/AAAA/MM - Mês/VRA_AAAAM.csv` (mês sem zero
  no nome do arquivo).
- CSV em UTF-8 com BOM; a 1ª linha é `Atualizado em: ...`, o cabeçalho é a 2ª.
- Colunas: ICAO Empresa Aérea; Número Voo; ICAO Aeródromo Origem/Destino;
  Partida/Chegada Prevista e Real; Situação Voo; Código Justificativa.

## Como validar (comandos do questionário, no Git Bash)
```
python -m py_compile scripts/fetch_flights.py
grep -n 'deduplicar\|def dedup' scripts/fetch_flights.py
grep -c 'innerHTML' index.html ; grep -c 'escapeHtml' index.html
```
Equivalente para o script do VRA: `python -m py_compile scripts/fetch_historico_anac.py`.

## Rodar localmente
- Painel: `python -m http.server 8000` na raiz e abrir `http://localhost:8000`
  (abrir o arquivo direto por `file://` falha, pois `data/airports.json` é
  carregado via `fetch`).
- Scripts: exigem `SUPABASE_URL` e `SUPABASE_SERVICE_KEY` no ambiente e
  **gravam no banco de produção**. Confirmar com a Ana antes de rodar.
- Rodar o pipeline na nuvem: aba Actions → "Run workflow"
  (`workflow_dispatch`); o de VRA aceita o input `ano_mes` (AAAA-MM).
