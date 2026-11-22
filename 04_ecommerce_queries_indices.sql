-- =====================================================================
-- 04_ecommerce_queries_indices.sql
-- Consultas analíticas, índices e exemplo de EXPLAIN ANALYZE para o banco
-- E-COMMERCE (schema ecommerce).
-- Pré-requisito: 02_ecommerce_schema.sql
-- =====================================================================

SET search_path TO ecommerce;

-- =====================================================================
-- PARTE A - EXPLAIN ANALYZE antes/depois do índice em pedido(id_cliente)
-- =====================================================================
-- Com os 15 pedidos de exemplo, o PostgreSQL sempre prefere Seq Scan
-- (ler a tabela inteira custa menos que consultar um índice). Para a
-- comparação ser realista, este bloco gera uma massa de teste dentro de
-- uma transação e desfaz tudo no final com ROLLBACK, inclusive o índice
-- criado aqui. Os dados de exemplo não são alterados.
--
-- No DBeaver, execute este bloco como script (Alt+X) e veja os planos
-- na aba de resultados de cada EXPLAIN.
-- Os tempos variam por máquina; o que importa é o tipo de nó do plano.
-- =====================================================================

BEGIN;

-- Garante o cenário "sem índice" mesmo se o script já foi executado antes
DROP INDEX IF EXISTS idx_pedido_cliente;

SELECT setseed(0.42);  -- deixa a massa aleatória reproduzível

-- 20.000 clientes PF fictícios (CPF iniciado por 9 para não colidir)
INSERT INTO cliente (tipo, nome, cpf, email, cidade, uf)
SELECT 'PF',
       'Cliente Teste ' || g,
       '9' || LPAD(g::text, 10, '0'),
       'cliente' || g || '@teste.com',
       'São Luís', 'MA'
FROM generate_series(1, 20000) AS g;

-- 200.000 pedidos distribuídos entre os clientes (~10 por cliente)
INSERT INTO pedido (id_cliente, data_pedido, status, frete)
SELECT (SELECT MIN(id_cliente) FROM cliente WHERE email LIKE '%@teste.com')
           + FLOOR(random() * 20000)::int,
       TIMESTAMP '2025-01-01' + random() * INTERVAL '700 days',
       'Concluído',
       ROUND((random() * 40)::numeric, 2)
FROM generate_series(1, 200000);

ANALYZE cliente;
ANALYZE pedido;

-- ANTES: sem índice em pedido(id_cliente)
-- Resultado esperado: "Seq Scan on pedido" (ou "Parallel Seq Scan") com
-- "Rows Removed by Filter"
-- na casa de 200 mil, ou seja, a tabela inteira é lida para achar ~10
-- pedidos de um único cliente.
EXPLAIN (ANALYZE, BUFFERS)
SELECT id_pedido, data_pedido, status
FROM pedido
WHERE id_cliente = (SELECT id_cliente FROM cliente WHERE email = 'cliente100@teste.com');

-- Cria o índice B-tree na coluna da FK
CREATE INDEX idx_pedido_cliente ON pedido USING btree (id_cliente);
ANALYZE pedido;

-- DEPOIS: com índice
-- Resultado esperado: "Bitmap Index Scan on idx_pedido_cliente" (ou
-- "Index Scan"), lendo apenas as poucas páginas que contêm os pedidos
-- daquele cliente. O tempo de execução cai de alguns milissegundos para
-- frações de milissegundo e o número de buffers lidos cai drasticamente.
EXPLAIN (ANALYZE, BUFFERS)
SELECT id_pedido, data_pedido, status
FROM pedido
WHERE id_cliente = (SELECT id_cliente FROM cliente WHERE email = 'cliente100@teste.com');

-- Desfaz a massa de teste e o índice temporário
ROLLBACK;

-- Garante que o search_path continua correto após o ROLLBACK
SET search_path TO ecommerce;

-- Sequências não voltam atrás com ROLLBACK. Realinha as sequências das
-- colunas IDENTITY ao maior ID real, para que novos cadastros continuem
-- a numeração dos dados de exemplo (11, 12, ... e não 20011).
SELECT setval(pg_get_serial_sequence('ecommerce.cliente', 'id_cliente'),
              (SELECT MAX(id_cliente) FROM cliente));
SELECT setval(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido'),
              (SELECT MAX(id_pedido) FROM pedido));

-- =====================================================================
-- PARTE B - ÍNDICES DEFINITIVOS
-- =====================================================================
-- Lembrete: diferente do MySQL/InnoDB, o PostgreSQL NÃO cria índice
-- automaticamente em colunas de FOREIGN KEY, apenas em PRIMARY KEY e
-- UNIQUE. Colunas de FK usadas em JOIN precisam de índice explícito.
--
-- Já cobertos por PK/UNIQUE (não precisam de índice novo):
--   * cliente(cpf), cliente(cnpj), cliente(email): UNIQUE.
--   * entrega(id_pedido) e entrega(codigo_rastreio): UNIQUE (a busca de
--     uma entrega pelo código de rastreio já usa esse índice).
--   * item_pedido(id_pedido): 1ª coluna da PK (id_pedido, id_produto).
--   * estoque(id_produto): 1ª coluna da PK (id_produto, id_local).
-- Não indexados por não serem usados nas consultas deste desafio:
--   pagamento(id_pedido), pagamento(id_forma), forma_pagamento(id_cliente),
--   estoque(id_local). Seriam os próximos candidatos em consultas de
--   conciliação de pagamentos ou de estoque por CD.
-- Não foi usado índice Hash: todas as colunas abaixo participam de JOIN
-- ou de filtro por intervalo/ordenação, e o B-tree atende igualdade E
-- intervalo/ordem com desempenho equivalente na igualdade.
-- =====================================================================

-- Índice 1: pedido(id_cliente)
--   Tipo: B-tree.
--   Por quê: FK para cliente e coluna de JOIN cliente -> pedido. Sem ele,
--   cada busca de pedidos de um cliente varre a tabela de pedidos inteira
--   (ver PARTE A). Também acelera o DELETE de clientes (checagem da FK).
--   Consulta atendida: Q1 (pedidos por cliente) e a opção 4 da procedure.
CREATE INDEX IF NOT EXISTS idx_pedido_cliente
    ON pedido USING btree (id_cliente);

-- Índice 2: item_pedido(id_produto)
--   Tipo: B-tree.
--   Por quê: FK para produto. A PK (id_pedido, id_produto) começa por
--   id_pedido e não serve para buscas por produto. É a coluna de JOIN
--   e de GROUP BY nas consultas de vendas por produto/categoria.
--   Consultas atendidas: Q2 (produtos mais vendidos) e
--   Q3 (faturamento por categoria).
CREATE INDEX IF NOT EXISTS idx_item_pedido_produto
    ON item_pedido USING btree (id_produto);

-- Índice 3: produto(id_categoria)
--   Tipo: B-tree.
--   Por quê: FK para categoria, coluna de JOIN produto -> categoria e de
--   filtro em listagens por categoria (vitrine da loja).
--   Consulta atendida: Q3 (faturamento por categoria).
CREATE INDEX IF NOT EXISTS idx_produto_categoria
    ON produto USING btree (id_categoria);

-- Índice 4: entrega(status, data_envio) parcial
--   Tipo: B-tree PARCIAL (WHERE status IN ('Aguardando envio', 'Em transporte')).
--   Por quê: status tem poucos valores distintos e, numa operação real,
--   a grande maioria das entregas está "Entregue". Um índice comum em
--   status seria grande e pouco seletivo. O índice parcial guarda só as
--   entregas em aberto (pequeno e barato de manter) e já as entrega
--   ordenadas por data de envio.
--   Consulta atendida: Q4b (acompanhamento de entregas em aberto), que
--   usa exatamente o mesmo predicado do índice.
CREATE INDEX IF NOT EXISTS idx_entrega_em_aberto
    ON entrega USING btree (status, data_envio)
    WHERE status IN ('Aguardando envio', 'Em transporte');

ANALYZE pedido;
ANALYZE item_pedido;
ANALYZE produto;
ANALYZE entrega;

-- =====================================================================
-- PARTE C - CONSULTAS ANALÍTICAS
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. Pedidos por cliente: quantidade de pedidos e valor total gasto
-- (itens + frete), desconsiderando pedidos cancelados.
-- A soma dos itens é feita numa subconsulta por pedido para evitar que
-- o frete seja somado várias vezes (uma vez por item).
-- ---------------------------------------------------------------------
WITH total_pedido AS (
    SELECT p.id_pedido,
           p.id_cliente,
           SUM(i.quantidade * i.valor_unitario) + p.frete AS valor_total
    FROM pedido p
    JOIN item_pedido i ON i.id_pedido = p.id_pedido
    WHERE p.status <> 'Cancelado'
    GROUP BY p.id_pedido, p.id_cliente, p.frete
)
SELECT c.id_cliente,
       c.nome,
       c.tipo                                  AS pf_pj,
       COUNT(t.id_pedido)                      AS qtd_pedidos,
       COALESCE(SUM(t.valor_total), 0)         AS valor_total,
       ROUND(AVG(t.valor_total), 2)            AS ticket_medio
FROM cliente c
LEFT JOIN total_pedido t ON t.id_cliente = c.id_cliente
GROUP BY c.id_cliente, c.nome, c.tipo
ORDER BY valor_total DESC;

-- ---------------------------------------------------------------------
-- Q2. Produtos mais vendidos (quantidade e receita), sem cancelados
-- ---------------------------------------------------------------------
SELECT pr.id_produto,
       pr.nome                                   AS produto,
       SUM(i.quantidade)                         AS unidades_vendidas,
       SUM(i.quantidade * i.valor_unitario)      AS receita,
       COUNT(DISTINCT i.id_pedido)               AS qtd_pedidos
FROM item_pedido i
JOIN produto pr ON pr.id_produto = i.id_produto
JOIN pedido  p  ON p.id_pedido   = i.id_pedido
WHERE p.status <> 'Cancelado'
GROUP BY pr.id_produto, pr.nome
ORDER BY unidades_vendidas DESC, receita DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q3. Faturamento por categoria, com participação percentual
-- ---------------------------------------------------------------------
SELECT ca.nome                                       AS categoria,
       SUM(i.quantidade * i.valor_unitario)          AS faturamento,
       ROUND(100.0 * SUM(i.quantidade * i.valor_unitario)
             / SUM(SUM(i.quantidade * i.valor_unitario)) OVER (), 2) AS participacao_pct
FROM categoria ca
JOIN produto     pr ON pr.id_categoria = ca.id_categoria
JOIN item_pedido i  ON i.id_produto    = pr.id_produto
JOIN pedido      p  ON p.id_pedido     = i.id_pedido
WHERE p.status <> 'Cancelado'
GROUP BY ca.nome
ORDER BY faturamento DESC;

-- ---------------------------------------------------------------------
-- Q4. Entregas por status, com prazo médio de entrega
-- (agregação sobre a tabela inteira: um Seq Scan é o plano correto aqui,
-- por isso esta consulta não tem índice dedicado)
-- ---------------------------------------------------------------------
SELECT status,
       COUNT(*)                                             AS qtd_entregas,
       ROUND(AVG(data_entrega - data_envio), 1)             AS prazo_medio_dias
FROM entrega
GROUP BY status
ORDER BY qtd_entregas DESC;

-- ---------------------------------------------------------------------
-- Q4b. Entregas em aberto: dias desde a compra e desde o envio.
-- O WHERE repete o predicado do índice parcial idx_entrega_em_aberto,
-- condição para o planejador poder usá-lo.
-- ---------------------------------------------------------------------
SELECT e.id_entrega,
       e.id_pedido,
       c.nome                                         AS cliente,
       e.status,
       e.codigo_rastreio,
       e.data_envio,
       CURRENT_DATE - p.data_pedido::date             AS dias_desde_compra,
       CURRENT_DATE - e.data_envio                    AS dias_em_transporte
FROM entrega e
JOIN pedido  p ON p.id_pedido  = e.id_pedido
JOIN cliente c ON c.id_cliente = p.id_cliente
WHERE e.status IN ('Aguardando envio', 'Em transporte')
ORDER BY e.status, e.data_envio NULLS FIRST;

-- ---------------------------------------------------------------------
-- Conferência: índices existentes no schema ecommerce
-- ---------------------------------------------------------------------
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'ecommerce'
ORDER BY tablename, indexname;
