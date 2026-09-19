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
