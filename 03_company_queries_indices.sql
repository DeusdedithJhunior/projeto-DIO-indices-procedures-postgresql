-- =====================================================================
-- 03_company_queries_indices.sql
-- Consultas do desafio e índices para o banco COMPANY (schema company).
-- Pré-requisito: 01_company_schema.sql
-- =====================================================================

SET search_path TO company;

-- ---------------------------------------------------------------------
-- ÍNDICES
-- ---------------------------------------------------------------------
-- Observação importante sobre PostgreSQL x MySQL:
-- No MySQL (InnoDB), toda FOREIGN KEY exige um índice na coluna
-- referenciadora, e o InnoDB o cria automaticamente se ele não existir.
-- O PostgreSQL NÃO faz isso: ele só cria índices automaticamente para
-- PRIMARY KEY e UNIQUE. Uma coluna de FK sem índice obriga o planejador
-- a varrer a tabela inteira (Seq Scan) em JOINs e também torna lentos
-- os DELETE/UPDATE na tabela pai (verificação da integridade).
-- Por isso, colunas de FK usadas em JOIN/GROUP BY recebem índice abaixo.
--
-- O que já está coberto e NÃO precisa de índice novo:
--   * employee(ssn), department(dnumber), project(pnumber): PKs.
--   * department(dname): UNIQUE já cria índice B-tree.
--   * dept_locations(dnumber): é a 1ª coluna da PK (dnumber, dlocation).
--   * works_on(essn) e dependent(essn): 1ª coluna das respectivas PKs.
-- Índices não criados por não haver consulta que os use neste desafio:
--   employee(super_ssn), project(dnum), works_on(pno). Seriam bons
--   candidatos se surgirem consultas de hierarquia ou de projetos.
-- ---------------------------------------------------------------------

-- Índice 1: employee(dno)
--   Tipo: B-tree (padrão do PostgreSQL).
--   Por quê: dno é FK para department e é a coluna de JOIN/GROUP BY
--   nas consultas 1 e 3. B-tree atende igualdade (JOIN) e também
--   ordenação, permitindo agrupar por dno lendo o índice já ordenado
--   (Index Only Scan na contagem por departamento).
--   Consultas atendidas: Q1 (departamento com mais pessoas) e
--   Q3 (empregados por departamento).
CREATE INDEX IF NOT EXISTS idx_employee_dno
    ON employee USING btree (dno);

-- Índice 2: dept_locations(dlocation, dnumber)
--   Tipo: B-tree composto.
--   Por quê: a PK (dnumber, dlocation) começa por dnumber, então não
--   serve para buscar/ordenar por cidade. Com dlocation na frente, a
--   Q2 consegue ler os pares cidade -> departamento já ordenados por
--   cidade e filtrar por uma cidade específica (WHERE dlocation = ...).
--   Incluir dnumber torna o índice "cobridor" (Index Only Scan).
--   Hash foi descartado porque não suporta ORDER BY nem índice composto.
--   Consulta atendida: Q2 (departamentos por cidade).
CREATE INDEX IF NOT EXISTS idx_dept_locations_location
    ON dept_locations USING btree (dlocation, dnumber);

-- Atualiza as estatísticas para o planejador considerar os índices
ANALYZE employee;
ANALYZE dept_locations;

-- ---------------------------------------------------------------------
-- Q1. Qual o departamento com maior número de pessoas?
-- RANK() trata empates: se dois departamentos tiverem o mesmo total,
-- ambos aparecem (um LIMIT 1 esconderia o empate).
-- ---------------------------------------------------------------------
WITH total_por_departamento AS (
    SELECT d.dnumber,
           d.dname,
           COUNT(e.ssn) AS qtd_empregados,
           RANK() OVER (ORDER BY COUNT(e.ssn) DESC) AS posicao
    FROM department d
    LEFT JOIN employee e ON e.dno = d.dnumber
    GROUP BY d.dnumber, d.dname
)
SELECT dnumber, dname, qtd_empregados
FROM total_por_departamento
WHERE posicao = 1;

-- ---------------------------------------------------------------------
-- Q2. Quais são os departamentos por cidade?
-- Versão detalhada (uma linha por cidade/departamento)...
-- ---------------------------------------------------------------------
SELECT l.dlocation AS cidade,
       d.dnumber,
       d.dname     AS departamento
FROM dept_locations l
JOIN department d ON d.dnumber = l.dnumber
ORDER BY l.dlocation, d.dname;

-- ...e versão resumida (uma linha por cidade)
SELECT l.dlocation                               AS cidade,
       COUNT(*)                                  AS qtd_departamentos,
       STRING_AGG(d.dname, ', ' ORDER BY d.dname) AS departamentos
FROM dept_locations l
JOIN department d ON d.dnumber = l.dnumber
GROUP BY l.dlocation
ORDER BY qtd_departamentos DESC, cidade;

-- Exemplo de filtro por cidade (usa diretamente idx_dept_locations_location
-- em tabelas maiores)
SELECT d.dname
FROM dept_locations l
JOIN department d ON d.dnumber = l.dnumber
WHERE l.dlocation = 'Houston';

-- ---------------------------------------------------------------------
-- Q3. Relação de empregados por departamento
-- ---------------------------------------------------------------------
SELECT d.dname                                   AS departamento,
       e.fname || ' ' || e.minit || '. ' || e.lname AS empregado,
       e.salary                                  AS salario,
       CASE WHEN e.ssn = d.mgr_ssn THEN 'Gerente' ELSE '' END AS observacao
FROM employee e
JOIN department d ON d.dnumber = e.dno
ORDER BY d.dname, e.fname, e.lname;

-- Resumo por departamento (quantidade, folha e média salarial)
SELECT d.dname                     AS departamento,
       COUNT(e.ssn)                AS qtd_empregados,
       SUM(e.salary)               AS folha_salarial,
       ROUND(AVG(e.salary), 2)     AS salario_medio
FROM department d
LEFT JOIN employee e ON e.dno = d.dnumber
GROUP BY d.dname
ORDER BY qtd_empregados DESC, departamento;

-- ---------------------------------------------------------------------
-- Conferência: índices existentes no schema company
-- ---------------------------------------------------------------------
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'company'
ORDER BY tablename, indexname;
