-- =====================================================================
-- 06_procedure_ecommerce.sql
-- Procedure de manutenção da tabela cliente (schema ecommerce).
-- Pré-requisito: 02_ecommerce_schema.sql
--
-- Variável de controle p_acao:
--   1 = consultar | 2 = inserir | 3 = atualizar | 4 = remover
--
-- Regras de negócio tratadas:
--   * Cliente é PF (com CPF) ou PJ (com CNPJ), nunca os dois
--     (CHECK chk_cliente_pf_pj). Na inserção/atualização, o documento
--     que não corresponde ao tipo é descartado automaticamente.
--   * CPF/CNPJ podem ser informados com ou sem máscara: a procedure
--     mantém apenas os dígitos.
--   * Cliente com pedidos não pode ser removido (FK fk_pedido_cliente).
--     Formas de pagamento são removidas em cascata.
--
-- Por que RAISE NOTICE na consulta (opção 1)?
--   Procedures do PostgreSQL não devolvem o resultado de um SELECT
--   como no MySQL. A opção 1 percorre os registros com FOR ... LOOP e
--   exibe cada linha com RAISE NOTICE, visível na aba "Output" do
--   DBeaver. Para consumir o resultado como tabela, o caminho seria uma
--   FUNCTION com RETURNS TABLE ou um parâmetro INOUT refcursor.
-- =====================================================================

SET search_path TO ecommerce;

CREATE OR REPLACE PROCEDURE ecommerce.sp_gerenciar_cliente(
    p_acao        INT,
    p_id_cliente  INT           DEFAULT NULL,
    p_tipo        CHAR(2)       DEFAULT NULL,
    p_nome        VARCHAR(100)  DEFAULT NULL,
    p_cpf         VARCHAR(14)   DEFAULT NULL,   -- aceita '123.456.789-00'
    p_cnpj        VARCHAR(18)   DEFAULT NULL,   -- aceita '12.345.678/0001-90'
    p_email       VARCHAR(100)  DEFAULT NULL,
    p_telefone    VARCHAR(15)   DEFAULT NULL,
    p_endereco    VARCHAR(150)  DEFAULT NULL,
    p_cidade      VARCHAR(50)   DEFAULT NULL,
    p_uf          CHAR(2)       DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    r           RECORD;
    v_qtd       INT := 0;
    v_id        INT;
    v_tipo      CHAR(2) := UPPER(p_tipo);
    -- Remove máscara (pontos, barras, traços); string vazia vira NULL
    v_cpf       TEXT := NULLIF(REGEXP_REPLACE(p_cpf,  '\D', '', 'g'), '');
    v_cnpj      TEXT := NULLIF(REGEXP_REPLACE(p_cnpj, '\D', '', 'g'), '');
    v_restricao TEXT;
BEGIN
    CASE p_acao

    -- -----------------------------------------------------------------
    -- 1 = CONSULTAR
    -- Filtros opcionais: p_id_cliente, p_tipo (PF/PJ) e p_cidade.
    -- Mostra também a quantidade de pedidos e o total comprado.
    -- -----------------------------------------------------------------
    WHEN 1 THEN
        RAISE NOTICE '--- Consulta de clientes ---';
        FOR r IN
            SELECT c.id_cliente,
                   c.tipo,
                   c.nome,
                   COALESCE(c.cpf, c.cnpj) AS documento,
                   c.email,
                   c.cidade || '/' || c.uf AS cidade_uf,
                   COUNT(p.id_pedido)      AS qtd_pedidos
            FROM ecommerce.cliente c
            LEFT JOIN ecommerce.pedido p ON p.id_cliente = c.id_cliente
            WHERE (p_id_cliente IS NULL OR c.id_cliente = p_id_cliente)
              AND (v_tipo       IS NULL OR c.tipo       = v_tipo)
              AND (p_cidade     IS NULL OR c.cidade     = p_cidade)
            GROUP BY c.id_cliente
            ORDER BY c.id_cliente
        LOOP
            v_qtd := v_qtd + 1;
            RAISE NOTICE 'ID: % | % | % | Doc: % | E-mail: % | Cidade: % | Pedidos: %',
                r.id_cliente, r.tipo, r.nome, r.documento, r.email,
                COALESCE(r.cidade_uf, '-'), r.qtd_pedidos;
        END LOOP;

        IF v_qtd = 0 THEN
            RAISE NOTICE 'Nenhum cliente encontrado para os filtros informados.';
        ELSE
            RAISE NOTICE 'Total: % registro(s).', v_qtd;
        END IF;

    -- -----------------------------------------------------------------
    -- 2 = INSERIR
    -- Obrigatórios: tipo, nome, e-mail e o documento do tipo (CPF ou CNPJ).
    -- -----------------------------------------------------------------
    WHEN 2 THEN
        IF v_tipo IS NULL OR p_nome IS NULL OR p_email IS NULL THEN
            RAISE EXCEPTION 'Para inserir, informe p_tipo (PF/PJ), p_nome e p_email.';
        END IF;
        IF v_tipo NOT IN ('PF', 'PJ') THEN
            RAISE EXCEPTION 'Tipo inválido: %. Use PF ou PJ.', v_tipo;
        END IF;
        IF v_tipo = 'PF' AND v_cpf IS NULL THEN
            RAISE EXCEPTION 'Cliente PF exige CPF (p_cpf).';
        ELSIF v_tipo = 'PJ' AND v_cnpj IS NULL THEN
            RAISE EXCEPTION 'Cliente PJ exige CNPJ (p_cnpj).';
        END IF;

        INSERT INTO ecommerce.cliente
            (tipo, nome, cpf, cnpj, email, telefone, endereco, cidade, uf)
        VALUES
            (v_tipo, p_nome,
             CASE WHEN v_tipo = 'PF' THEN v_cpf  END,   -- descarta o documento
             CASE WHEN v_tipo = 'PJ' THEN v_cnpj END,   -- que não é do tipo
             LOWER(p_email), p_telefone, p_endereco, p_cidade, UPPER(p_uf))
        RETURNING id_cliente INTO v_id;

        RAISE NOTICE 'Cliente % "%" inserido com sucesso. ID gerado: %.', v_tipo, p_nome, v_id;

    -- -----------------------------------------------------------------
    -- 3 = ATUALIZAR
    -- Atualiza só os campos informados. Se o tipo mudar (PF <-> PJ), o
    -- documento antigo é limpo e o novo documento passa a ser exigido
    -- (a CHECK chk_cliente_pf_pj barra o caso sem documento).
    -- -----------------------------------------------------------------
    WHEN 3 THEN
        IF p_id_cliente IS NULL THEN
            RAISE EXCEPTION 'Para atualizar, informe o p_id_cliente.';
        END IF;
        IF v_tipo IS NOT NULL AND v_tipo NOT IN ('PF', 'PJ') THEN
            RAISE EXCEPTION 'Tipo inválido: %. Use PF ou PJ.', v_tipo;
        END IF;

        UPDATE ecommerce.cliente c
           SET tipo     = COALESCE(v_tipo, c.tipo),
               nome     = COALESCE(p_nome, c.nome),
               cpf      = CASE WHEN COALESCE(v_tipo, c.tipo) = 'PF'
                               THEN COALESCE(v_cpf, c.cpf) END,
               cnpj     = CASE WHEN COALESCE(v_tipo, c.tipo) = 'PJ'
                               THEN COALESCE(v_cnpj, c.cnpj) END,
               email    = COALESCE(LOWER(p_email), c.email),
               telefone = COALESCE(p_telefone, c.telefone),
               endereco = COALESCE(p_endereco, c.endereco),
               cidade   = COALESCE(p_cidade, c.cidade),
               uf       = COALESCE(UPPER(p_uf), c.uf)
         WHERE c.id_cliente = p_id_cliente;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Cliente com ID % não encontrado. Nada foi atualizado.', p_id_cliente;
        END IF;

        RAISE NOTICE 'Cliente % atualizado com sucesso.', p_id_cliente;

    -- -----------------------------------------------------------------
    -- 4 = REMOVER
    -- -----------------------------------------------------------------
    WHEN 4 THEN
        IF p_id_cliente IS NULL THEN
            RAISE EXCEPTION 'Para remover, informe o p_id_cliente.';
        END IF;

        DELETE FROM ecommerce.cliente WHERE id_cliente = p_id_cliente;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Cliente com ID % não encontrado. Nada foi removido.', p_id_cliente;
        END IF;

        RAISE NOTICE 'Cliente % removido com sucesso (formas de pagamento removidas em cascata).', p_id_cliente;

    ELSE
        RAISE EXCEPTION 'Ação inválida: %. Use 1 = consultar, 2 = inserir, 3 = atualizar, 4 = remover.',
            COALESCE(p_acao::text, 'NULL');
    END CASE;

EXCEPTION
    WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_restricao = CONSTRAINT_NAME;
        RAISE NOTICE 'Erro: já existe cliente com este %.',
            CASE v_restricao
                WHEN 'cliente_cpf_key'   THEN 'CPF'
                WHEN 'cliente_cnpj_key'  THEN 'CNPJ'
                WHEN 'cliente_email_key' THEN 'e-mail'
                ELSE 'valor único (' || v_restricao || ')'
            END;

    WHEN foreign_key_violation THEN
        RAISE NOTICE 'Erro: o cliente % possui pedidos e não pode ser removido. Mantenha o cadastro para preservar o histórico.', p_id_cliente;

    WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_restricao = CONSTRAINT_NAME;
        RAISE NOTICE 'Erro: dados inválidos (restrição %). %', v_restricao,
            CASE v_restricao
                WHEN 'chk_cliente_pf_pj'  THEN 'PF exige CPF e PJ exige CNPJ, nunca os dois.'
                WHEN 'chk_cliente_cpf'    THEN 'CPF deve ter 11 dígitos.'
                WHEN 'chk_cliente_cnpj'   THEN 'CNPJ deve ter 14 dígitos.'
                WHEN 'cliente_tipo_check' THEN 'Tipo deve ser PF ou PJ.'
                ELSE ''
            END;

    WHEN string_data_right_truncation THEN
        RAISE NOTICE 'Erro: valor maior que o tamanho da coluna. Detalhe: %', SQLERRM;

    WHEN not_null_violation THEN
        RAISE NOTICE 'Erro: campo obrigatório não informado. Detalhe: %', SQLERRM;

    WHEN raise_exception THEN
        RAISE NOTICE 'Erro: %', SQLERRM;

    WHEN OTHERS THEN
        RAISE NOTICE 'Erro inesperado [%]: %', SQLSTATE, SQLERRM;
END;
$$;

COMMENT ON PROCEDURE ecommerce.sp_gerenciar_cliente IS
    'Manutenção de cliente (PF/PJ). p_acao: 1=consultar, 2=inserir, 3=atualizar, 4=remover.';

-- =====================================================================
-- CHAMADAS DE EXEMPLO
-- =====================================================================

-- 1 = CONSULTAR
CALL ecommerce.sp_gerenciar_cliente(1);                                 -- todos
CALL ecommerce.sp_gerenciar_cliente(1, p_tipo => 'PJ');                 -- só PJ
CALL ecommerce.sp_gerenciar_cliente(1, p_cidade => 'São Luís');         -- por cidade

-- 2 = INSERIR (PF com CPF mascarado e PJ)
CALL ecommerce.sp_gerenciar_cliente(
    p_acao     => 2,
    p_tipo     => 'PF',
    p_nome     => 'Helena Castro Viana',
    p_cpf      => '999.888.777-66',
    p_email    => 'Helena.Viana@email.com',
    p_telefone => '98991110011',
    p_endereco => 'Rua do Giz, 15',
    p_cidade   => 'São Luís',
    p_uf       => 'ma'
);
CALL ecommerce.sp_gerenciar_cliente(
    p_acao   => 2,
    p_tipo   => 'PJ',
    p_nome   => 'Distribuidora Litoral Ltda',
    p_cnpj   => '11.222.333/0001-44',
    p_email  => 'compras@litoral.com.br',
    p_cidade => 'Teresina',
    p_uf     => 'PI'
);
CALL ecommerce.sp_gerenciar_cliente(1, p_cidade => 'São Luís');         -- confere

-- 3 = ATUALIZAR
-- Os IDs dos clientes recém-inseridos são buscados pelo e-mail com um
-- bloco DO, para os exemplos funcionarem mesmo que a numeração varie.
DO $$
DECLARE
    v_id INT;
BEGIN
    SELECT id_cliente INTO v_id FROM ecommerce.cliente WHERE email = 'helena.viana@email.com';
    -- muda nome, cidade e endereço (demais campos permanecem)
    CALL ecommerce.sp_gerenciar_cliente(3, p_id_cliente => v_id,
                                        p_nome     => 'Helena Castro Viana Lima',
                                        p_endereco => 'Av. Litorânea, 500',
                                        p_cidade   => 'São José de Ribamar');
    CALL ecommerce.sp_gerenciar_cliente(1, p_id_cliente => v_id);
END;
$$;

-- 4 = REMOVER (cliente sem pedidos)
DO $$
DECLARE
    v_id INT;
BEGIN
    SELECT id_cliente INTO v_id FROM ecommerce.cliente WHERE email = 'compras@litoral.com.br';
    CALL ecommerce.sp_gerenciar_cliente(4, p_id_cliente => v_id);
    CALL ecommerce.sp_gerenciar_cliente(1, p_id_cliente => v_id);       -- não encontrado
END;
$$;

-- Remove também o cliente PF de exemplo, para o script poder ser
-- executado de novo sem erro de duplicidade
DO $$
DECLARE
    v_id INT;
BEGIN
    SELECT id_cliente INTO v_id FROM ecommerce.cliente WHERE email = 'helena.viana@email.com';
    CALL ecommerce.sp_gerenciar_cliente(4, p_id_cliente => v_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Exemplos de tratamento de erro (geram apenas NOTICE, sem interromper)
-- ---------------------------------------------------------------------
CALL ecommerce.sp_gerenciar_cliente(2, p_tipo => 'PF', p_nome => 'Teste CPF Repetido',
                                    p_cpf => '11122233344', p_email => 'teste1@email.com');   -- CPF duplicado
CALL ecommerce.sp_gerenciar_cliente(2, p_tipo => 'PJ', p_nome => 'Empresa Sem CNPJ',
                                    p_email => 'teste2@email.com');                             -- PJ sem CNPJ
CALL ecommerce.sp_gerenciar_cliente(2, p_tipo => 'PF', p_nome => 'CPF Curto',
                                    p_cpf => '123', p_email => 'teste3@email.com');            -- CHECK CPF
CALL ecommerce.sp_gerenciar_cliente(2, p_tipo => 'XX', p_nome => 'Tipo Errado',
                                    p_cpf => '12312312312', p_email => 'teste4@email.com');    -- CHECK tipo
CALL ecommerce.sp_gerenciar_cliente(3, p_id_cliente => 1, p_tipo => 'PJ');                     -- vira PJ sem CNPJ
CALL ecommerce.sp_gerenciar_cliente(4, p_id_cliente => 1);                                     -- possui pedidos
CALL ecommerce.sp_gerenciar_cliente(4, p_id_cliente => 9999);                                  -- não existe
CALL ecommerce.sp_gerenciar_cliente(0);                                                        -- ação inválida
