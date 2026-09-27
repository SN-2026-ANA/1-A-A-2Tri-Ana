# Uso de IA — Ana

Registro do uso de inteligência artificial neste projeto, conforme a nota do
passo D4 do gabarito.

## Ferramenta

- **IA:** Claude (Anthropic), modelo Claude Opus 5.5
- **Ambiente:** Claude Code, no aplicativo desktop do Claude
- **Data:** 27/09/2026

## Prompts utilizados

1. "Preciso fazer um projeto para minha aula de serviços em nuvem, seguindo esse
   gabarito aqui. O que faltar e precisar pode me pedir, porém sem interferir no
   outro projeto que fizemos antes" (com o PDF `SN-2026-gabarito-2Trim.pdf` anexado)
2. Envio dos arquivos da pasta "Base Atividade Complementar" do Drive
   (`index.html`, `fetch_flights.py`, `fetch_historico_anac.py`,
   `update-flights.yml`, `importar-historico.yml`): "Se faltar algum arquivo me
   avise qual"

## Principais retornos

- A IA leu o gabarito e apontou que o nome `1-A-A-2Tri-Ana` era usado como
  redirecionamento do projeto anterior (renomeado para `1-A-A-2Tri-Ana-2`).
  Antes de criar o repositório novo, o endereço da pasta local antiga foi
  corrigido para que ela continuasse enviando para o projeto anterior.
- Criou o repositório `SN-2026-ANA/1-A-A-2Tri-Ana` e importou o projeto base
  `SN-2026-GIL/01-06-2026-Anac-Supabase` com todo o histórico (Fase A).
- Aplicou os arquivos da v2 exatamente como vieram do Drive, usando as mensagens
  de commit indicadas no gabarito.
- Apontou os erros conhecidos que o próprio gabarito manda corrigir e aplicou
  cada ajuste em um commit separado:
  - **1-B:** função `deduplicar` no `fetch_flights.py`;
  - **1-A e 2-A:** URL, codificação e cabeçalho do CSV real do VRA no
    `fetch_historico_anac.py`.
- Avisou que o `sql/setup.sql` não estava entre os arquivos do Drive nem no
  projeto base.

## O que foi feito manualmente (sem IA)

- Criação do projeto no Supabase e convite ao professor (B1 e B2)
- Cadastro dos Secrets `SUPABASE_URL` e `SUPABASE_SERVICE_KEY` (C2); a chave
  `service_role` não foi compartilhada com a IA
- Prints das evidências
