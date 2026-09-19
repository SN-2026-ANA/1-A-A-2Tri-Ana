"""
fetch_historico_anac.py — Dados históricos ANAC/VRA + Supabase
Busca o arquivo VRA (Voo Regular Ativo) do portal de dados abertos da ANAC,
processa e insere na tabela historico_vra do Supabase.

Execução: mensal (dia 3 de cada mês via GitHub Actions)

Correções v4 (com base no arquivo real da ANAC):
  - URL correta: .../Voo Regular Ativo (VRA)/AAAA/MM - Mês/VRA_AAAAM.csv
  - Arquivo em UTF-8 (com BOM), e não latin-1
  - A 1ª linha é "Atualizado em: AAAA-MM-DD"; o cabeçalho real vem depois
  - Colunas reais: "ICAO Empresa Aérea", "Partida Prevista", "Situação Voo"...
  - Datas no formato "AAAA-MM-DD HH:MM:SS"
  - Não há coluna de data de referência: usa a data da partida prevista
  - Remove duplicatas antes do upsert (deduplicar)

Variáveis de ambiente:
  SUPABASE_URL         → URL do projeto (GitHub Secret)
  SUPABASE_SERVICE_KEY → secret key / service_role key (GitHub Secret)
  AIRPORTS             → ICAOs para filtrar (GitHub Variable)
  ANO_MES              → Período a buscar no formato AAAA-MM
                         Padrão: mês anterior ao atual
"""

import csv
import io
import os
import sys
from datetime import datetime, timezone, timedelta
from urllib.parse import quote

import requests
from supabase import create_client

# ── Credenciais ───────────────────────────────────────────────────────────────

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip()
SUPABASE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()

if not SUPABASE_URL or not SUPABASE_KEY:
    print("[ERRO CRÍTICO] SUPABASE_URL e SUPABASE_SERVICE_KEY são obrigatórios.")
    sys.exit(1)

db = create_client(SUPABASE_URL, SUPABASE_KEY)
print(f"Supabase conectado: {SUPABASE_URL}")

# ── Configurações ─────────────────────────────────────────────────────────────

airports_env = os.environ.get("AIRPORTS", "SBCA")
AIRPORTS     = [a.strip().upper() for a in airports_env.split(",") if a.strip()]
LOTE         = 500

# Período: usa mês anterior por padrão (o VRA do mês atual fica disponível
# somente após o fechamento do mês)
BRT  = timezone(timedelta(hours=-3))
hoje = datetime.now(BRT)

if os.environ.get("ANO_MES"):
    ano_mes = os.environ["ANO_MES"].strip()  # ex: 2026-04
else:
    primeiro_do_mes = hoje.replace(day=1)
    mes_anterior    = primeiro_do_mes - timedelta(days=1)
    ano_mes         = mes_anterior.strftime("%Y-%m")

ano, mes = ano_mes.split("-")
mes_num  = int(mes)

print(f"Período histórico: {ano_mes}")
print(f"Aeroportos filtrados: {', '.join(AIRPORTS)}")

# ── URL do VRA ────────────────────────────────────────────────────────────────
# Estrutura do portal ANAC (o nome do arquivo usa o mês SEM zero à esquerda):
# /Voos e operações aéreas/Voo Regular Ativo (VRA)/2026/06 - Junho/VRA_20266.csv

MESES = {
    1: "Janeiro", 2: "Fevereiro", 3: "Março",    4: "Abril",
    5: "Maio",    6: "Junho",     7: "Julho",    8: "Agosto",
    9: "Setembro", 10: "Outubro", 11: "Novembro", 12: "Dezembro",
}

VRA_URL = (
    "https://sistemas.anac.gov.br/dadosabertos/"
    + quote(
        f"Voos e operações aéreas/Voo Regular Ativo (VRA)/"
        f"{ano}/{mes_num:02d} - {MESES[mes_num]}/VRA_{ano}{mes_num}.csv"
    )
)

# Mapeamento de colunas do CSV do VRA
# (primeiro nome = cabeçalho real do arquivo; os demais são variações antigas)
COLS = {
    "empresa":       ["ICAO Empresa Aérea", "EMPRESA (SIGLA)", "sg_empresa_icao"],
    "voo":           ["Número Voo", "NÚMERO VOO", "nr_voo"],
    "origem":        ["ICAO Aeródromo Origem", "ORIGEM", "sg_icao_origem"],
    "destino":       ["ICAO Aeródromo Destino", "DESTINO", "sg_icao_destino"],
    "partida_prev":  ["Partida Prevista", "PARTIDA PREVISTA"],
    "partida_real":  ["Partida Real", "PARTIDA REAL"],
    "chegada_prev":  ["Chegada Prevista", "CHEGADA PREVISTA"],
    "chegada_real":  ["Chegada Real", "CHEGADA REAL"],
    "situacao":      ["Situação Voo", "SITUAÇÃO DE VOO", "situacao"],
    "motivo":        ["Código Justificativa", "MOTIVO", "motivo_alteracao"],
}

FORMATOS_DT = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%d/%m/%Y %H:%M:%S",
    "%d/%m/%Y %H:%M",
)


def get_col(row: dict, key: str) -> str:
    """Tenta múltiplos nomes de coluna para compatibilidade entre versões do CSV."""
    for nome in COLS.get(key, [key]):
        if nome in row:
            return (row[nome] or "").strip()
    return ""


def parse_dt(dt_str: str) -> datetime | None:
    """Converte texto de data/hora da ANAC em datetime (sem fuso)."""
    dt_str = (dt_str or "").strip()
    if not dt_str:
        return None
    for fmt in FORMATOS_DT:
        try:
            return datetime.strptime(dt_str, fmt)
        except ValueError:
            continue
    return None


def parse_dt_anac(dt_str: str) -> str | None:
    """Converte data/hora da ANAC para ISO com timezone UTC."""
    dt = parse_dt(dt_str)
    return dt.replace(tzinfo=timezone.utc).isoformat() if dt else None


def diff_minutos(previsto: str, real: str) -> int | None:
    """Calcula atraso em minutos entre horário previsto e real."""
    dp, dr = parse_dt(previsto), parse_dt(real)
    if not dp or not dr:
        return None
    return int((dr - dp).total_seconds() / 60)


CHAVE_UNICA = ("ano_mes", "icao_empresa", "nr_voo",
               "icao_origem", "icao_destino", "dt_referencia")


def deduplicar(registros: list) -> tuple[list, int]:
    """Remove duplicatas pela mesma chave usada no on_conflict do upsert.

    O upsert do Supabase falha se um mesmo lote tiver duas linhas com a mesma
    chave. Mantém a última ocorrência. Retorna (únicos, qtd_removidos).
    """
    unicos = {}
    for r in registros:
        unicos[tuple(r[c] for c in CHAVE_UNICA)] = r
    return list(unicos.values()), len(registros) - len(unicos)


# ── Busca o arquivo VRA ───────────────────────────────────────────────────────

def baixar_vra() -> list[dict]:
    print(f"\nGET {VRA_URL}")
    try:
        r = requests.get(VRA_URL, timeout=120)
        if r.status_code == 404:
            print("  Não encontrado (404) — o VRA deste mês ainda não foi publicado.")
            return []
        r.raise_for_status()
        # O arquivo é UTF-8 com BOM (utf-8-sig remove o BOM)
        texto  = r.content.decode("utf-8-sig", errors="replace")
        linhas = texto.splitlines()
        # A 1ª linha é "Atualizado em: AAAA-MM-DD"; o cabeçalho real vem depois
        inicio = next((i for i, l in enumerate(linhas) if "ICAO" in l.upper()), 0)
        print(f"  Cabeçalho detectado (linha {inicio + 1}): {linhas[inicio]}")
        reader    = csv.DictReader(io.StringIO("\n".join(linhas[inicio:])), delimiter=";")
        registros = list(reader)
        print(f"  VRA carregado: {len(registros)} linhas brutas")
        return registros
    except Exception as e:
        print(f"  [ERRO] {e}")
        return []


# ── Processa e filtra registros ───────────────────────────────────────────────

def processar_vra(linhas: list[dict]) -> list[dict]:
    resultado = []
    for row in linhas:
        origem  = get_col(row, "origem").upper()
        destino = get_col(row, "destino").upper()
        if origem not in AIRPORTS and destino not in AIRPORTS:
            continue

        empresa       = get_col(row, "empresa")
        nr_voo        = get_col(row, "voo")
        partida_prev  = get_col(row, "partida_prev")
        partida_real  = get_col(row, "partida_real")
        chegada_prev  = get_col(row, "chegada_prev")
        chegada_real  = get_col(row, "chegada_real")
        situacao      = get_col(row, "situacao")
        motivo        = get_col(row, "motivo")

        # O VRA não traz data de referência: usa a data da partida prevista
        dt_base = parse_dt(partida_prev) or parse_dt(chegada_prev)
        dt_ref  = dt_base.date().isoformat() if dt_base else None

        # Sem os campos da chave, o upsert não consegue evitar duplicatas
        if not (empresa and nr_voo and origem and destino and dt_ref):
            continue

        resultado.append({
            "ano_mes":          ano_mes,
            "icao_empresa":     empresa,
            "nr_voo":           nr_voo,
            "icao_origem":      origem,
            "icao_destino":     destino,
            "dt_referencia":    dt_ref,
            "partida_real":     parse_dt_anac(partida_real),
            "chegada_real":     parse_dt_anac(chegada_real),
            "atraso_partida":   diff_minutos(partida_prev, partida_real),
            "atraso_chegada":   diff_minutos(chegada_prev, chegada_real),
            "situacao":         situacao.lower() if situacao else None,
            "motivo_alteracao": None if motivo.upper() in ("", "N/A") else motivo,
        })

    print(f"  Registros filtrados para os aeroportos configurados: {len(resultado)}")
    return resultado


def escrever_summary(brutas: int, filtrados: int, duplicados: int,
                     processados: int, erros: int) -> None:
    """Grava um resumo na aba Summary do run no GitHub Actions."""
    caminho = os.environ.get("GITHUB_STEP_SUMMARY")
    if not caminho:
        return
    with open(caminho, "a", encoding="utf-8") as f:
        f.write(f"### Importar Histórico ANAC/VRA — {ano_mes}\n\n")
        f.write("| Métrica | Valor |\n|---|---|\n")
        f.write(f"| Linhas brutas no VRA | {brutas} |\n")
        f.write(f"| Filtradas para os aeroportos | {filtrados} |\n")
        f.write(f"| Duplicados removidos | {duplicados} |\n")
        f.write(f"| Enviados/processados | {processados} |\n")
        f.write(f"| Lotes com erro | {erros} |\n")


# ── Inserção no Supabase ──────────────────────────────────────────────────────

linhas_vra  = baixar_vra()
if not linhas_vra:
    print("\n[AVISO] VRA não disponível para o período. Encerrando.")
    sys.exit(0)

registros           = processar_vra(linhas_vra)
registros, duplicados = deduplicar(registros)
print(f"  Duplicados removidos antes do envio: {duplicados}")

processados = 0
erros       = 0

for i in range(0, len(registros), LOTE):
    lote     = registros[i:i + LOTE]
    num_lote = i // LOTE + 1
    try:
        db.table("historico_vra").upsert(
            lote,
            on_conflict="ano_mes,icao_empresa,nr_voo,icao_origem,icao_destino,dt_referencia",
        ).execute()
        processados += len(lote)
        print(f"  Lote {num_lote}: {len(lote)} registros enviados/processados")
    except Exception as e:
        erros += 1
        print(f"  [ERRO] Lote {num_lote}: {e}")

print(f"\nConcluído — {processados} registros históricos enviados/processados.")
escrever_summary(len(linhas_vra), len(registros) + duplicados, duplicados,
                 processados, erros)
if erros > 0:
    print(f"[ATENÇÃO] {erros} lote(s) com erro.")
    sys.exit(1)
