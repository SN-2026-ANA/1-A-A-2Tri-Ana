# Projeto SN-2026

Painel de voos com dados diários do SIROS/ANAC e histórico VRA da ANAC, armazenados no Supabase e exibidos em uma interface web pública no GitHub Pages.

O projeto combina:
- um pipeline no GitHub Actions que busca voos do dia na API SIROS;
- um segundo workflow que importa o histórico VRA mensalmente;
- um front-end em HTML + JavaScript que lê os dados diretamente do Supabase;
- um banco PostgreSQL no Supabase com políticas de leitura pública e escrita restrita ao fluxo de dados.

## O que o projeto faz

### Fluxo diário de voos
O script [scripts/fetch_flights.py](scripts/fetch_flights.py) consulta a API SIROS para a data atual em BRT, filtra os voos dos aeroportos configurados e envia os registros para a tabela `voos` no Supabase.

Ele também:
- remove duplicatas antes do upsert;
- grava logs na tabela `execucoes`;
- marca status como `concluido`, `erro_parcial`, `erro_critico` ou `sem_dados`;
- faz o workflow falhar no GitHub Actions quando há erro em qualquer lote.

### Histórico ANAC/VRA
O script [scripts/fetch_historico_anac.py](scripts/fetch_historico_anac.py) busca o arquivo VRA da ANAC, processa os dados e grava na tabela `historico_vra` no Supabase.

Esse fluxo é executado mensalmente e usa o período informado em `ANO_MES` ou, se não informado, o mês anterior ao atual.

### Painel web
O arquivo [index.html](index.html) lê os dados das tabelas `voos`, `historico_vra` e `execucoes` via REST do Supabase. A interface mostra voos do dia, histórico, filtros por aeroporto e dados do pipeline.

## Estrutura de pastas

- `.github/workflows/` — workflows do GitHub Actions
  - `update-flights.yml` — execução diária dos voos do dia
  - `importar-historico.yml` — importação mensal do VRA
- `scripts/`
  - `fetch_flights.py` — coleta e grava voos do SIROS
  - `fetch_historico_anac.py` — coleta e grava histórico VRA
- `sql/`
  - `setup.sql` — criação de tabelas, constraints, RLS e políticas
- `data/`
  - `airports.json` — cadastro de aeroportos usado pelo front-end
- `index.html` — painel web
- `README.md` — documentação do projeto

## Variáveis de ambiente

As variáveis abaixo são usadas pelos scripts executados no GitHub Actions.

| Nome | Tipo no GitHub | Uso | Onde configurar |
| --- | --- | --- | --- |
| `SUPABASE_URL` | Secret | URL do projeto Supabase | Secret |
| `SUPABASE_SERVICE_KEY` | Secret | Chave `service_role` do Supabase | Secret |
| `AIRPORTS` | Variable | Lista de ICAOs separados por vírgula | Variable |
| `ANO_MES` | Input do workflow | Período a buscar no formato `AAAA-MM` | Input do workflow |

### `SUPABASE_URL`
- Tipo: GitHub Secret
- Uso: URL do projeto Supabase
- Necessária para conectar os scripts ao banco

### `SUPABASE_SERVICE_KEY`
- Tipo: GitHub Secret
- Uso: chave `service_role` do Supabase
- Necessária para escrever nas tabelas do banco
- O projeto informa que ela deve ficar apenas no GitHub Secret e nunca no código, commits ou logs

### `AIRPORTS`
- Tipo: GitHub Variable
- Uso: lista de ICAOs separados por vírgula
- Exemplo: `SBCA,SBGR,SBSP,SBCT`
- Essa configuração é usada para filtrar voos e VRA por aeroporto

### `ANO_MES` (workflow de histórico)
- Tipo: input do workflow
- Formato: `AAAA-MM`
- Exemplo: `2026-04`
- Se não informado, o script usa o mês anterior ao atual

## Como rodar os workflows no GitHub Actions

### 1. Configurar os segredos e variáveis no GitHub
No repositório, acesse Settings → Secrets and variables → Actions.

Defina:
- `SUPABASE_URL` como secret
- `SUPABASE_SERVICE_KEY` como secret
- `AIRPORTS` como variable, por exemplo: `SBCA,SBGR,SBSP,SBCT,SBGL,SBBR,SBFL,SBPA,SBSV,SBFZ`

### 2. Executar o pipeline diário de voos
O workflow [`.github/workflows/update-flights.yml`](.github/workflows/update-flights.yml) está agendado para rodar em horários do dia com cron UTC:
- `0 9,12,15,21 * * *`

Isso corresponde a 06h, 09h, 12h e 18h no horário de Brasília (BRT).

Também é possível disparar manualmente:
- Acesse a aba `Actions`
- Escolha `Pipeline SIROS → Supabase`
- Clique em `Run workflow`

Esse workflow executa:
- `python scripts/fetch_flights.py`
- com `AIRPORTS`, `SUPABASE_URL` e `SUPABASE_SERVICE_KEY` no ambiente

### 3. Executar a importação do histórico VRA
O workflow [`.github/workflows/importar-historico.yml`](.github/workflows/importar-historico.yml) está agendado para rodar no dia 3 de cada mês às 09h UTC.

Também pode ser disparado manualmente:
- Acesse a aba `Actions`
- Escolha `Importar Histórico ANAC/VRA`
- Clique em `Run workflow`
- Informe `ano_mes` no formato `AAAA-MM` se quiser importar um período específico

Esse workflow executa:
- `python scripts/fetch_historico_anac.py`
- com `AIRPORTS`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` e `ANO_MES` no ambiente

## Como rodar o painel localmente

O front-end pode ser servido localmente com:

```bash
python -m http.server 8000
```

Depois, abra no navegador:

```text
http://localhost:8000
```

O projeto informa que abrir o arquivo direto por `file://` pode falhar porque o front-end carrega dados em `fetch` do arquivo `data/airports.json`.

## Observações importantes

- O banco é configurado em [sql/setup.sql](sql/setup.sql) com criação de tabelas, constraints, RLS e políticas.
- A chave `service_role` deve permanecer apenas no GitHub Secret e nunca em arquivos de código.
- O painel usa a chave pública `anon` do Supabase para leitura e o banco restringe escrita ao fluxo de dados.
- Os scripts são executados no ambiente do GitHub Actions e gravam diretamente no banco de produção, conforme a configuração do projeto.

## Dados e fontes

- SIROS/ANAC: voos do dia
- ANAC/VRA: histórico mensal
- Supabase: armazenamento e leitura pública
- GitHub Actions: execução automatizada dos workflows

## Capturas de tela

<img width="1366" height="637" alt="Screenshot_20260615_093442" src="https://github.com/user-attachments/assets/1ef0c7a8-0d5d-465e-9184-c77f42bf8f6c" />
<img width="1366" height="637" alt="Screenshot_20260615_093616" src="https://github.com/user-attachments/assets/894358f9-b760-4a6c-b3ed-837df0663d26" />

