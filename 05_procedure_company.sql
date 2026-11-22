-- =====================================================================
-- 05_procedure_company.sql
-- Procedure de manutenção da tabela employee (schema company).
-- Pré-requisito: 01_company_schema.sql
--
-- Variável de controle p_acao:
--   1 = consultar | 2 = inserir | 3 = atualizar | 4 = remover
--
-- Por que RAISE NOTICE na consulta (opção 1)?
--   No MySQL, um SELECT solto dentro de uma procedure devolve o resultado
--   direto para o cliente. No PostgreSQL isso não acontece: uma PROCEDURE
--   não retorna conjuntos de linhas e um SELECT sem destino dentro do
--   PL/pgSQL gera erro ("query has no destination for result data").
--   As alternativas seriam: (a) uma FUNCTION com RETURNS TABLE, (b) um
--   parâmetro INOUT do tipo refcursor, lido depois com FETCH. Como o
--   desafio pede uma única procedure com variável de controle, a opção 1
--   percorre os registros com FOR ... LOOP e exibe cada linha com
--   RAISE NOTICE. No DBeaver as mensagens aparecem na aba "Output"
--   (habilite em "Show server output", ícone na barra do editor SQL).
--
-- Tratamento de erros:
--   O bloco EXCEPTION captura violações de restrição (PK, FK, CHECK,
--   NOT NULL, tamanho) e erros de validação levantados pela própria
--   procedure (RAISE EXCEPTION). Em vez de interromper o script, a
--   procedure exibe uma mensagem clara com RAISE NOTICE. Quando um erro
--   é capturado, o PostgreSQL desfaz automaticamente o que foi feito
--   dentro do bloco, então nenhum dado fica pela metade.
-- =====================================================================

SET search_path TO company;

CREATE OR REPLACE PROCEDURE company.sp_gerenciar_employee(
    p_acao       INT,
    p_ssn        CHAR(9)        DEFAULT NULL,
    p_fname      VARCHAR(15)    DEFAULT NULL,
    p_minit      CHAR(1)        DEFAULT NULL,
    p_lname      VARCHAR(15)    DEFAULT NULL,
    p_bdate      DATE           DEFAULT NULL,
    p_address    VARCHAR(50)    DEFAULT NULL,
    p_sex        CHAR(1)        DEFAULT NULL,
    p_salary     NUMERIC(10,2)  DEFAULT NULL,
    p_super_ssn  CHAR(9)        DEFAULT NULL,
    p_dno        INT            DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    r           RECORD;
    v_qtd       INT := 0;
    v_detalhe   TEXT;
    v_restricao TEXT;
BEGIN
    CASE p_acao

    -- -----------------------------------------------------------------
    -- 1 = CONSULTAR
    -- Filtros opcionais: p_ssn (um empregado) e/ou p_dno (departamento).
    -- Sem filtros, lista todos.
    -- -----------------------------------------------------------------
    WHEN 1 THEN
        RAISE NOTICE '--- Consulta de empregados ---';
        FOR r IN
            SELECT e.ssn,
                   e.fname || ' ' || COALESCE(e.minit || '. ', '') || e.lname AS nome,
                   e.salary,
                   e.dno,
                   d.dname,
                   s.fname || ' ' || s.lname AS supervisor
            FROM company.employee e
            LEFT JOIN company.department d ON d.dnumber = e.dno
            LEFT JOIN company.employee   s ON s.ssn     = e.super_ssn
            WHERE (p_ssn IS NULL OR e.ssn = p_ssn)
              AND (p_dno IS NULL OR e.dno = p_dno)
            ORDER BY e.dno, e.fname
        LOOP
            v_qtd := v_qtd + 1;
            RAISE NOTICE 'SSN: % | Nome: % | Salário: % | Depto: % - % | Supervisor: %',
                r.ssn, r.nome, r.salary, r.dno, r.dname, COALESCE(r.supervisor, '(nenhum)');
        END LOOP;

        IF v_qtd = 0 THEN
            RAISE NOTICE 'Nenhum empregado encontrado para os filtros informados.';
        ELSE
            RAISE NOTICE 'Total: % registro(s).', v_qtd;
        END IF;

    -- -----------------------------------------------------------------
    -- 2 = INSERIR
    -- Obrigatórios: ssn, fname, lname e dno.
    -- -----------------------------------------------------------------
    WHEN 2 THEN
        IF p_ssn IS NULL OR p_fname IS NULL OR p_lname IS NULL OR p_dno IS NULL THEN
            RAISE EXCEPTION 'Para inserir, informe p_ssn, p_fname, p_lname e p_dno.';
        END IF;

        INSERT INTO company.employee
            (ssn, fname, minit, lname, bdate, address, sex, salary, super_ssn, dno)
        VALUES
            (p_ssn, p_fname, p_minit, p_lname, p_bdate, p_address, p_sex, p_salary, p_super_ssn, p_dno);

        RAISE NOTICE 'Empregado % (% %) inserido com sucesso no departamento %.',
            p_ssn, p_fname, p_lname, p_dno;

    -- -----------------------------------------------------------------
    -- 3 = ATUALIZAR
    -- Atualiza só os campos informados (os NULL mantêm o valor atual).
    -- -----------------------------------------------------------------
    WHEN 3 THEN
        IF p_ssn IS NULL THEN
            RAISE EXCEPTION 'Para atualizar, informe o p_ssn do empregado.';
        END IF;

        UPDATE company.employee
           SET fname     = COALESCE(p_fname,     fname),
               minit     = COALESCE(p_minit,     minit),
               lname     = COALESCE(p_lname,     lname),
               bdate     = COALESCE(p_bdate,     bdate),
               address   = COALESCE(p_address,   address),
               sex       = COALESCE(p_sex,       sex),
               salary    = COALESCE(p_salary,    salary),
               super_ssn = COALESCE(p_super_ssn, super_ssn),
               dno       = COALESCE(p_dno,       dno)
         WHERE ssn = p_ssn;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Empregado com SSN % não encontrado. Nada foi atualizado.', p_ssn;
        END IF;

        RAISE NOTICE 'Empregado % atualizado com sucesso.', p_ssn;

    -- -----------------------------------------------------------------
    -- 4 = REMOVER
    -- works_on e dependent são removidos em cascata; subordinados ficam
    -- sem supervisor (ON DELETE SET NULL). Gerente de departamento não
    -- pode ser removido (FK de department.mgr_ssn).
    -- -----------------------------------------------------------------
    WHEN 4 THEN
        IF p_ssn IS NULL THEN
            RAISE EXCEPTION 'Para remover, informe o p_ssn do empregado.';
        END IF;

        DELETE FROM company.employee WHERE ssn = p_ssn;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Empregado com SSN % não encontrado. Nada foi removido.', p_ssn;
        END IF;

        RAISE NOTICE 'Empregado % removido com sucesso (projetos e dependentes removidos em cascata).', p_ssn;

    ELSE
        RAISE EXCEPTION 'Ação inválida: %. Use 1 = consultar, 2 = inserir, 3 = atualizar, 4 = remover.',
            COALESCE(p_acao::text, 'NULL');
    END CASE;

EXCEPTION
    WHEN unique_violation THEN
        RAISE NOTICE 'Erro: já existe um empregado com o SSN %.', p_ssn;

    WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_detalhe = PG_EXCEPTION_DETAIL,
                                v_restricao = CONSTRAINT_NAME;
        IF v_restricao = 'fk_department_manager' THEN
            RAISE NOTICE 'Erro: o empregado % é gerente de um departamento. Troque o gerente antes de removê-lo.', p_ssn;
        ELSIF v_restricao = 'fk_employee_department' THEN
            RAISE NOTICE 'Erro: o departamento % não existe.', p_dno;
        ELSIF v_restricao = 'fk_employee_supervisor' THEN
            RAISE NOTICE 'Erro: o supervisor % não existe.', p_super_ssn;
        ELSE
            RAISE NOTICE 'Erro de chave estrangeira (%): %', v_restricao, v_detalhe;
        END IF;

    WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_restricao = CONSTRAINT_NAME;
        RAISE NOTICE 'Erro: valor inválido (restrição %). Verifique sexo (M/F) e salário (> 0).', v_restricao;

    WHEN not_null_violation THEN
        RAISE NOTICE 'Erro: campo obrigatório não informado. Detalhe: %', SQLERRM;

    WHEN string_data_right_truncation THEN
        RAISE NOTICE 'Erro: valor maior que o tamanho da coluna (ex.: SSN deve ter 9 caracteres). Detalhe: %', SQLERRM;

    WHEN raise_exception THEN
        -- Erros de validação levantados pela própria procedure
        RAISE NOTICE 'Erro: %', SQLERRM;

    WHEN OTHERS THEN
        RAISE NOTICE 'Erro inesperado [%]: %', SQLSTATE, SQLERRM;
END;
$$;

COMMENT ON PROCEDURE company.sp_gerenciar_employee IS
    'Manutenção de employee. p_acao: 1=consultar, 2=inserir, 3=atualizar, 4=remover.';

-- =====================================================================
-- CHAMADAS DE EXEMPLO
-- A notação nomeada (parametro => valor) deixa claro o que é cada
-- argumento e permite omitir os que têm DEFAULT.
-- =====================================================================

-- 1 = CONSULTAR
CALL company.sp_gerenciar_employee(1);                                  -- todos
CALL company.sp_gerenciar_employee(1, p_dno => 5);                      -- por departamento
CALL company.sp_gerenciar_employee(1, p_ssn => '123456789');            -- um empregado

-- 2 = INSERIR
CALL company.sp_gerenciar_employee(
    p_acao      => 2,
    p_ssn       => '555666777',
    p_fname     => 'Beatriz',
    p_minit     => 'C',
    p_lname     => 'Santos',
    p_bdate     => '1995-05-10',
    p_address   => '200 Elm, Houston, TX',
    p_sex       => 'F',
    p_salary    => 31000,
    p_super_ssn => '333445555',
    p_dno       => 5
);
CALL company.sp_gerenciar_employee(1, p_ssn => '555666777');            -- confere

-- 3 = ATUALIZAR (apenas salário e endereço)
CALL company.sp_gerenciar_employee(3, p_ssn => '555666777', p_salary => 34500, p_address => '18 Oak, Bellaire, TX');
CALL company.sp_gerenciar_employee(1, p_ssn => '555666777');            -- confere

-- 4 = REMOVER
CALL company.sp_gerenciar_employee(4, p_ssn => '555666777');
CALL company.sp_gerenciar_employee(1, p_ssn => '555666777');            -- não encontrado

-- ---------------------------------------------------------------------
-- Exemplos de tratamento de erro (geram apenas NOTICE, sem interromper)
-- ---------------------------------------------------------------------
CALL company.sp_gerenciar_employee(2, p_ssn => '123456789', p_fname => 'Teste', p_lname => 'Duplicado', p_dno => 5); -- PK duplicada
CALL company.sp_gerenciar_employee(2, p_ssn => '000000001', p_fname => 'Teste', p_lname => 'SemDepto',  p_dno => 99); -- FK inexistente
CALL company.sp_gerenciar_employee(2, p_ssn => '000000002', p_fname => 'Teste', p_lname => 'Salario',   p_dno => 5, p_salary => -10); -- CHECK
CALL company.sp_gerenciar_employee(2, p_ssn => '000000003');                                                          -- faltam campos
CALL company.sp_gerenciar_employee(3, p_ssn => '999999999', p_salary => 50000);                                       -- não existe
CALL company.sp_gerenciar_employee(4, p_ssn => '333445555');                                                          -- é gerente
CALL company.sp_gerenciar_employee(9);                                                                                -- ação inválida
