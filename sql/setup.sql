-- ═══════════════════════════════════════════════════════════════════════════
-- SN-2026 / Supabase — Setup v2
-- Correções aplicadas:
--   - 41 aeroportos sem duplicatas (SBSV único, SBRP e SBUL incluídos)
--   - Tabela execucoes com voos_processados, lotes_enviados, erros
--   - GRANTs explícitos para anon e service_role
--   - Separação entre políticas RLS (quem pode) e GRANTs (o que pode)
-- Execute no SQL Editor do Supabase — seguro para reexecutar (idempotente)
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1. Tabela aeroportos ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS aeroportos (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    icao   text   NOT NULL,
    iata   text,
    nome   text   NOT NULL,
    cidade text   NOT NULL,
    estado text   NOT NULL,
    lat    float8,
    lon    float8
);

CREATE UNIQUE INDEX IF NOT EXISTS aeroportos_icao_idx ON aeroportos (icao);


-- ── 2. Tabela voos ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS voos (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    data_referencia date        NOT NULL,
    icao_empresa    text        NOT NULL,
    nome_empresa    text,
    numero_voo      text        NOT NULL,
    etapa           text,
    icao_origem     text        NOT NULL,
    icao_destino    text        NOT NULL,
    hr_partida_utc  time,
    hr_chegada_utc  time,
    partida_iso     timestamptz,
    chegada_iso     timestamptz,
    equipamento     text,
    assentos        integer,
    tipo_operacao   text,
    tipo_servico    text,
    criado_em       timestamptz NOT NULL DEFAULT now()
);

-- Constraint de unicidade para o upsert diário
-- Garante que o mesmo voo não seja duplicado na mesma data
ALTER TABLE voos DROP CONSTRAINT IF EXISTS voos_unique;
ALTER TABLE voos ADD CONSTRAINT voos_unique
    UNIQUE (data_referencia, icao_empresa, numero_voo, icao_origem, icao_destino, etapa);

-- Índices para acelerar as consultas do painel
CREATE INDEX IF NOT EXISTS idx_voos_data    ON voos (data_referencia DESC);
CREATE INDEX IF NOT EXISTS idx_voos_destino ON voos (icao_destino);
CREATE INDEX IF NOT EXISTS idx_voos_origem  ON voos (icao_origem);
CREATE INDEX IF NOT EXISTS idx_voos_empresa ON voos (icao_empresa);


-- ── 3. Tabela execucoes (log do pipeline) ────────────────────────────────────
-- v2: voos_processados substitui voos_inseridos; adicionados lotes_enviados e erros
DROP TABLE IF EXISTS execucoes;

CREATE TABLE execucoes (
    id                   bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iniciado_em          timestamptz NOT NULL DEFAULT now(),
    concluido_em         timestamptz,
    aeroportos_buscados  text[],
    -- "processados" reflete o upsert: insert + update sem duplicação
    voos_processados     integer     DEFAULT 0,
    lotes_enviados       integer     DEFAULT 0,
    erros                integer     DEFAULT 0,
    -- "concluido" | "erro_parcial" | "sem_dados" | "erro_critico"
    status               text        DEFAULT 'em_andamento',
    observacao           text
);

-- Índice para consultas recentes
CREATE INDEX IF NOT EXISTS idx_exec_concluido ON execucoes (concluido_em DESC);


-- ── 4. View auxiliar voos_completo ───────────────────────────────────────────
CREATE OR REPLACE VIEW voos_completo AS
SELECT
    v.*,
    ao.nome   AS nome_origem,
    ao.cidade AS cidade_origem,
    ao.estado AS estado_origem,
    ad.nome   AS nome_destino,
    ad.cidade AS cidade_destino,
    ad.estado AS estado_destino
FROM voos v
LEFT JOIN aeroportos ao ON ao.icao = v.icao_origem
LEFT JOIN aeroportos ad ON ad.icao = v.icao_destino;


-- ── 5. RLS — Segurança por linha ─────────────────────────────────────────────
-- Nota sobre chaves:
--   publishable key (anon key em projetos legados): pode ser usada no frontend
--   porque não concede privilégios administrativos por si só — a segurança
--   depende da combinação entre permissões do banco, RLS e policies.
--
--   secret key (service_role key em projetos legados): deve ficar apenas em
--   ambientes controlados como GitHub Actions, backend, Edge Functions ou
--   funções serverless. Nunca deve aparecer no index.html, commits ou prints.

ALTER TABLE aeroportos ENABLE ROW LEVEL SECURITY;
ALTER TABLE voos       ENABLE ROW LEVEL SECURITY;
ALTER TABLE execucoes  ENABLE ROW LEVEL SECURITY;

-- Políticas: define QUEM pode fazer O QUÊ
DROP POLICY IF EXISTS "leitura publica aeroportos" ON aeroportos;
CREATE POLICY "leitura publica aeroportos"
    ON aeroportos FOR SELECT USING (true);

DROP POLICY IF EXISTS "leitura publica voos" ON voos;
CREATE POLICY "leitura publica voos"
    ON voos FOR SELECT USING (true);

DROP POLICY IF EXISTS "leitura publica execucoes" ON execucoes;
CREATE POLICY "leitura publica execucoes"
    ON execucoes FOR SELECT USING (true);

-- Sem políticas de INSERT/UPDATE/DELETE → apenas service_role pode escrever


-- ── 6. GRANTs explícitos ─────────────────────────────────────────────────────
-- GRANTs definem permissões no nível do banco (camada abaixo do RLS).
-- O RLS filtra linhas; o GRANT define o que o role pode fazer na tabela.
-- Sem GRANT explícito, projetos novos do Supabase podem negar acesso
-- mesmo com política RLS correta.

-- anon (publishable key): apenas leitura
GRANT SELECT ON TABLE aeroportos   TO anon;
GRANT SELECT ON TABLE voos         TO anon;
GRANT SELECT ON TABLE execucoes    TO anon;
GRANT SELECT ON TABLE voos_completo TO anon;

-- authenticated: mesma leitura (usuários logados, se houver auth futura)
GRANT SELECT ON TABLE aeroportos   TO authenticated;
GRANT SELECT ON TABLE voos         TO authenticated;
GRANT SELECT ON TABLE execucoes    TO authenticated;
GRANT SELECT ON TABLE voos_completo TO authenticated;

-- service_role (secret key): acesso total para o pipeline
GRANT ALL ON TABLE aeroportos  TO service_role;
GRANT ALL ON TABLE voos        TO service_role;
GRANT ALL ON TABLE execucoes   TO service_role;

-- Sequences: necessário para INSERT com GENERATED ALWAYS AS IDENTITY
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;


-- ── 7. Inserção dos 41 aeroportos ────────────────────────────────────────────
-- 41 aeroportos — sem duplicatas
-- SBSV aparece apenas uma vez
-- SBRP (Ribeirão Preto/SP) e SBUL (Uberlândia/MG) incluídos
-- ON CONFLICT: seguro para reexecutar sem perder dados existentes

INSERT INTO aeroportos (icao, iata, nome, cidade, estado, lat, lon) VALUES
    -- Região Sul
    ('SBCA', 'CAC', 'Aeroporto Regional do Oeste',        'Cascavel',        'Paraná',              -24.9679, -53.5008),
    ('SBCT', 'CWB', 'Afonso Pena Internacional',          'Curitiba',        'Paraná',              -25.5285, -49.1758),
    ('SBLO', 'LDB', 'General Leite de Castro',            'Londrina',        'Paraná',              -23.3336, -51.1301),
    ('SBMG', 'MGF', 'Silvio Name Júnior Regional',        'Maringá',         'Paraná',              -23.4764, -52.0122),
    ('SBFI', 'IGU', 'Cataratas Internacional',            'Foz do Iguaçu',   'Paraná',              -25.6003, -54.4852),
    ('SBFL', 'FLN', 'Hercílio Luz Internacional',         'Florianópolis',   'Santa Catarina',      -27.6702, -48.5525),
    ('SBJV', 'JOI', 'Lauro Carneiro de Loyola',           'Joinville',       'Santa Catarina',      -26.2245, -48.7975),
    ('SBNF', 'NVT', 'Min. Victor Konder Internacional',   'Navegantes',      'Santa Catarina',      -26.8800, -48.6513),
    ('SBPA', 'POA', 'Salgado Filho Internacional',        'Porto Alegre',    'Rio Grande do Sul',   -29.9944, -51.1714),
    ('SBCX', 'CXJ', 'Hugo Cantergiani Regional',          'Caxias do Sul',   'Rio Grande do Sul',   -29.1971, -51.1875),
    -- Região Sudeste
    ('SBGR', 'GRU', 'Guarulhos Internacional',            'Guarulhos',       'São Paulo',           -23.4356, -46.4731),
    ('SBSP', 'CGH', 'Congonhas',                          'São Paulo',       'São Paulo',           -23.6261, -46.6564),
    ('SBKP', 'VCP', 'Viracopos Internacional',            'Campinas',        'São Paulo',           -23.0074, -47.1345),
    ('SBRP', 'RAO', 'Leite Lopes',                        'Ribeirão Preto',  'São Paulo',           -21.1363, -47.7766),
    ('SBGL', 'GIG', 'Galeão Internacional',               'Rio de Janeiro',  'Rio de Janeiro',      -22.8099, -43.2506),
    ('SBRJ', 'SDU', 'Santos Dumont',                      'Rio de Janeiro',  'Rio de Janeiro',      -22.9105, -43.1631),
    ('SBCF', 'CNF', 'Tancredo Neves Internacional',       'Belo Horizonte',  'Minas Gerais',        -19.6244, -43.9720),
    ('SBUL', 'UDI', 'Ten. Cel. Aviador César Bombonato',  'Uberlândia',      'Minas Gerais',        -18.8836, -48.2253),
    ('SBMK', 'MOC', 'Mário Ribeiro',                      'Montes Claros',   'Minas Gerais',        -16.7069, -43.8189),
    ('SBVT', 'VIX', 'Eurico de Aguiar Salles',            'Vitória',         'Espírito Santo',      -20.2581, -40.2864),
    -- Região Centro-Oeste
    ('SBBR', 'BSB', 'JK Internacional',                   'Brasília',        'Distrito Federal',    -15.8711, -47.9186),
    ('SBGO', 'GYN', 'Santa Genoveva',                     'Goiânia',         'Goiás',               -16.6320, -49.2207),
    ('SBCY', 'CGB', 'Marechal Rondon Internacional',       'Cuiabá',          'Mato Grosso',         -15.6530, -56.1167),
    ('SBCG', 'CGR', 'Antonio João Internacional',          'Campo Grande',    'Mato Grosso do Sul',  -20.4687, -54.6725),
    -- Região Nordeste
    ('SBSV', 'SSA', 'Dep. Luís Eduardo Magalhães',        'Salvador',        'Bahia',               -12.9086, -38.3225),
    ('SBFZ', 'FOR', 'Pinto Martins Internacional',        'Fortaleza',       'Ceará',               -3.7762,  -38.5326),
    ('SBRF', 'REC', 'Guararapes Internacional',           'Recife',          'Pernambuco',          -8.1265,  -34.9237),
    ('SBSL', 'SLZ', 'Cunha Machado Internacional',        'São Luís',        'Maranhão',            -2.5855,  -44.2341),
    ('SBTE', 'THE', 'Sen. Petrônio Portella',             'Teresina',        'Piauí',               -5.0600,  -42.8237),
    ('SBJP', 'JPA', 'Pres. Castro Pinto Internacional',  'João Pessoa',     'Paraíba',             -7.1458,  -34.9508),
    ('SBMO', 'MCZ', 'Zumbi dos Palmares Internacional',  'Maceió',          'Alagoas',             -9.5108,  -35.7917),
    ('SBSE', 'AJU', 'Santa Maria',                        'Aracaju',         'Sergipe',             -10.9847, -37.0703),
    ('SBSG', 'NAT', 'São Gonçalo do Amarante Internacional','Natal',         'Rio Grande do Norte', -5.7681,  -35.3764),
    -- Região Norte
    ('SBEG', 'MAO', 'Eduardo Gomes Internacional',        'Manaus',          'Amazonas',            -3.0386,  -60.0497),
    ('SBBE', 'BEL', 'Val-de-Cans Internacional',          'Belém',           'Pará',                -1.3793,  -48.4764),
    ('SBSN', 'STM', 'Maestro Wilson Fonseca',             'Santarém',        'Pará',                -2.4242,  -54.7858),
    ('SBMQ', 'MCP', 'Alberto Alcolumbre Internacional',   'Macapá',          'Amapá',                0.0506,  -51.0722),
    ('SBBV', 'BVB', 'Atlas Brasil Cantanhede Internacional','Boa Vista',     'Roraima',              2.8414,  -60.6922),
    ('SBPV', 'PVH', 'Gov. Jorge Teixeira de Oliveira',    'Porto Velho',     'Rondônia',            -8.7093,  -63.9023),
    ('SBRB', 'RBR', 'Plácido de Castro Internacional',    'Rio Branco',      'Acre',                -9.8688,  -67.8981),
    ('SBPJ', 'PMW', 'Brig. Lysias Rodrigues',             'Palmas',          'Tocantins',          -10.2913,  -48.3569)
ON CONFLICT (icao) DO UPDATE SET
    iata   = EXCLUDED.iata,
    nome   = EXCLUDED.nome,
    cidade = EXCLUDED.cidade,
    estado = EXCLUDED.estado,
    lat    = EXCLUDED.lat,
    lon    = EXCLUDED.lon;


-- ── 8. Tabela historico_vra (dados históricos ANAC) ──────────────────────────
-- Alimentada pelo script fetch_historico_anac.py (execução mensal)
CREATE TABLE IF NOT EXISTS historico_vra (
    id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ano_mes          text        NOT NULL,  -- formato: YYYY-MM
    icao_empresa     text        NOT NULL,
    nr_voo           text        NOT NULL,
    icao_origem      text,
    icao_destino     text,
    dt_referencia    date,
    partida_real     timestamptz,
    chegada_real     timestamptz,
    atraso_partida   integer,               -- minutos
    atraso_chegada   integer,               -- minutos
    situacao         text,                  -- realizado, cancelado, desviado
    motivo_alteracao text,
    importado_em     timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS vra_unique_idx
    ON historico_vra (ano_mes, icao_empresa, nr_voo, icao_origem, icao_destino, dt_referencia);

CREATE INDEX IF NOT EXISTS idx_vra_ano_mes   ON historico_vra (ano_mes DESC);
CREATE INDEX IF NOT EXISTS idx_vra_destino   ON historico_vra (icao_destino);
CREATE INDEX IF NOT EXISTS idx_vra_situacao  ON historico_vra (situacao);

-- RLS e GRANTs para historico_vra
ALTER TABLE historico_vra ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leitura publica historico_vra" ON historico_vra;
CREATE POLICY "leitura publica historico_vra"
    ON historico_vra FOR SELECT USING (true);

GRANT SELECT ON TABLE historico_vra TO anon;
GRANT SELECT ON TABLE historico_vra TO authenticated;
GRANT ALL    ON TABLE historico_vra TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;


-- ── Verificação final ─────────────────────────────────────────────────────────
SELECT tablename AS tabela,
       rowsecurity AS rls_ativo
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('aeroportos','voos','execucoes','historico_vra')
ORDER BY tablename;

SELECT COUNT(*) AS total_aeroportos FROM aeroportos;
-- Resultado esperado: 41
