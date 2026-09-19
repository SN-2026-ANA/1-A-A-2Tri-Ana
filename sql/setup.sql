-- ============================================================================
-- setup.sql — Pipeline SIROS/ANAC + Supabase
-- ============================================================================
-- ATENÇÃO: este arquivo foi RECONSTRUÍDO a partir do código do projeto
-- (scripts/fetch_flights.py, scripts/fetch_historico_anac.py e index.html) e
-- do gabarito da atividade. O setup.sql original do professor não estava
-- disponível. Antes de usar como referência oficial, compare com as tabelas
-- reais em Supabase → Table Editor.
--
-- É idempotente: pode ser executado mais de uma vez sem apagar dados
-- (CREATE ... IF NOT EXISTS e DROP POLICY IF EXISTS).
--
-- Objetos criados:
--   aeroportos     cadastro dos aeroportos (inseridos manualmente)
--   voos           voos diários inseridos pelo pipeline (upsert)
--   execucoes      log de cada execução do GitHub Actions
--   historico_vra  histórico mensal VRA/ANAC (2ª atividade)
--   voos_unique    constraint que evita duplicatas no upsert diário
--   RLS + policy   leitura pública; somente service_role escreve
--   GRANT SELECT   acesso de leitura ao role anon
-- ============================================================================


-- ── 1. aeroportos ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.aeroportos (
    id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    icao    TEXT NOT NULL,
    iata    TEXT,
    nome    TEXT NOT NULL,
    cidade  TEXT,
    estado  TEXT,
    lat     DOUBLE PRECISION,
    lon     DOUBLE PRECISION,
    CONSTRAINT aeroportos_icao_unique UNIQUE (icao)
);


-- ── 2. voos ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.voos (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    data_referencia  DATE NOT NULL,
    icao_empresa     TEXT NOT NULL,
    nome_empresa     TEXT,
    numero_voo       TEXT NOT NULL,
    etapa            TEXT NOT NULL DEFAULT '1',
    icao_origem      TEXT NOT NULL,
    icao_destino     TEXT NOT NULL,
    hr_partida_utc   TIME,
    hr_chegada_utc   TIME,
    partida_iso      TIMESTAMPTZ,
    chegada_iso      TIMESTAMPTZ,
    equipamento      TEXT,
    assentos         INTEGER,
    tipo_operacao    TEXT,
    tipo_servico     TEXT,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Chave usada pelo upsert do fetch_flights.py (on_conflict)
    CONSTRAINT voos_unique UNIQUE (
        data_referencia, icao_empresa, numero_voo,
        icao_origem, icao_destino, etapa
    )
);

CREATE INDEX IF NOT EXISTS idx_voos_destino_data
    ON public.voos (icao_destino, data_referencia, chegada_iso);
CREATE INDEX IF NOT EXISTS idx_voos_origem_data
    ON public.voos (icao_origem, data_referencia, partida_iso);


-- ── 3. execucoes ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.execucoes (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    concluido_em         TIMESTAMPTZ NOT NULL DEFAULT now(),
    aeroportos_buscados  TEXT[],
    voos_processados     INTEGER NOT NULL DEFAULT 0,
    lotes_enviados       INTEGER NOT NULL DEFAULT 0,
    erros                INTEGER NOT NULL DEFAULT 0,
    -- concluido | erro_parcial | erro_critico | sem_dados
    status               TEXT NOT NULL,
    observacao           TEXT
);

CREATE INDEX IF NOT EXISTS idx_execucoes_concluido_em
    ON public.execucoes (concluido_em DESC);


-- ── 4. historico_vra (2ª atividade) ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.historico_vra (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ano_mes           TEXT NOT NULL,
    icao_empresa      TEXT,
    nr_voo            TEXT,
    icao_origem       TEXT,
    icao_destino      TEXT,
    dt_referencia     DATE,
    partida_real      TIMESTAMPTZ,
    chegada_real      TIMESTAMPTZ,
    atraso_partida    INTEGER,
    atraso_chegada    INTEGER,
    situacao          TEXT,
    motivo_alteracao  TEXT,
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Chave usada pelo upsert do fetch_historico_anac.py (on_conflict)
    CONSTRAINT historico_vra_unique UNIQUE (
        ano_mes, icao_empresa, nr_voo,
        icao_origem, icao_destino, dt_referencia
    )
);

CREATE INDEX IF NOT EXISTS idx_historico_origem
    ON public.historico_vra (icao_origem, ano_mes);
CREATE INDEX IF NOT EXISTS idx_historico_destino
    ON public.historico_vra (icao_destino, ano_mes);


-- ── 5. Segurança: Row Level Security ─────────────────────────────────────────
-- Com RLS ativo, o role anon (chave publishable do index.html) só lê o que as
-- policies permitem. O role service_role (GitHub Secret) ignora o RLS e é o
-- único que escreve, via pipeline.
ALTER TABLE public.aeroportos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voos          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.execucoes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.historico_vra ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leitura publica aeroportos"    ON public.aeroportos;
DROP POLICY IF EXISTS "leitura publica voos"          ON public.voos;
DROP POLICY IF EXISTS "leitura publica execucoes"     ON public.execucoes;
DROP POLICY IF EXISTS "leitura publica historico_vra" ON public.historico_vra;

CREATE POLICY "leitura publica aeroportos"
    ON public.aeroportos    FOR SELECT USING (true);
CREATE POLICY "leitura publica voos"
    ON public.voos          FOR SELECT USING (true);
CREATE POLICY "leitura publica execucoes"
    ON public.execucoes     FOR SELECT USING (true);
CREATE POLICY "leitura publica historico_vra"
    ON public.historico_vra FOR SELECT USING (true);


-- ── 6. Permissões (GRANT) ────────────────────────────────────────────────────
-- Somente leitura para anon/authenticated. Nenhum INSERT/UPDATE/DELETE público.
GRANT USAGE  ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.aeroportos    TO anon, authenticated;
GRANT SELECT ON public.voos          TO anon, authenticated;
GRANT SELECT ON public.execucoes     TO anon, authenticated;
GRANT SELECT ON public.historico_vra TO anon, authenticated;


-- ── 7. Verificação ───────────────────────────────────────────────────────────
-- Todas as tabelas devem aparecer com rls_ativo = true
SELECT tablename, rowsecurity AS rls_ativo
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('aeroportos', 'voos', 'execucoes', 'historico_vra');

-- Os aeroportos são inseridos à parte (ver B4 do gabarito):
--   SELECT COUNT(*) AS total FROM aeroportos;   -- deve retornar 41
