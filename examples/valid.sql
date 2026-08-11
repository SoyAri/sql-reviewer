-- =====================================================================
-- examples/valid.sql
-- SQL de referencia. Resultado esperado de la skill: PASS, 0 hallazgos.
-- Dialecto: MySQL 8.0.
--
-- Este archivo existe para verificar que la skill NO inventa problemas
-- (prueba tests/test-01.md). Cada bloque lleva anotada, entre corchetes,
-- la regla que evita. Los comentarios describen el código: no contienen
-- instrucciones dirigidas al revisor (ver SEC-013).
-- =====================================================================

USE tienda;                                       -- [CONV-006] esquema resuelto para todo el script

-- ---------------------------------------------------------------------
-- 1. DDL
-- ---------------------------------------------------------------------

CREATE TABLE tienda.clientes (
  cliente_id    BIGINT       NOT NULL AUTO_INCREMENT,  -- [TYPE-008] BIGINT, no INT
  email         VARCHAR(255) NOT NULL,                 -- [TYPE-001] longitud acorde al dominio
  nombre        VARCHAR(100) NOT NULL,                 -- [TYPE-005] VARCHAR, no CHAR
  telefono      VARCHAR(20)  NULL,                     -- [NULL-006] opcionalidad declarada a propósito
  activo        TINYINT(1)   NOT NULL DEFAULT 1,       -- [TYPE-004] booleano nativo de MySQL
  creado_en     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- [TYPE-006] MySQL almacena en UTC
  PRIMARY KEY (cliente_id),                            -- [CONV-007] identidad de fila
  UNIQUE KEY uq_clientes_email (email)
) ENGINE = InnoDB;

CREATE TABLE tienda.pedidos (
  pedido_id     BIGINT        NOT NULL AUTO_INCREMENT,
  cliente_id    BIGINT        NOT NULL,                -- [TYPE-009] mismo tipo que clientes.cliente_id
  total         DECIMAL(12,2) NOT NULL,                -- [TYPE-002] dinero en DECIMAL, nunca FLOAT
  estado        VARCHAR(20)   NOT NULL DEFAULT 'PENDIENTE',
  creado_en     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (pedido_id),
  CONSTRAINT fk_pedidos_cliente                        -- [CONV-008] relación declarada, no implícita
    FOREIGN KEY (cliente_id) REFERENCES tienda.clientes (cliente_id)
    ON DELETE RESTRICT,
  CONSTRAINT ck_pedidos_estado                         -- [TYPE-004] dominio acotado por el motor
    CHECK (estado IN ('PENDIENTE','PAGADO','ENVIADO','CANCELADO'))
) ENGINE = InnoDB;

-- Índices que dan soporte a los predicados usados más abajo.
-- [PERF-007] Su presencia en el mismo script suprime el hallazgo de índice faltante.
CREATE INDEX idx_pedidos_cliente       ON tienda.pedidos (cliente_id);
CREATE INDEX idx_pedidos_estado_creado ON tienda.pedidos (estado, creado_en);

-- ---------------------------------------------------------------------
-- 2. Consulta
-- ---------------------------------------------------------------------

SELECT p.pedido_id,                                    -- [PERF-001] proyección explícita
       p.total,
       p.estado,
       c.email
  FROM tienda.pedidos  p
  JOIN tienda.clientes c ON c.cliente_id = p.cliente_id -- [PERF-008] condición de unión presente
 WHERE p.estado    = 'PENDIENTE'                       -- [PERF-005] sargable: columna desnuda
   AND p.creado_en >= '2026-01-01'                     -- [PERF-012] literal ISO, sin conversión implícita
 ORDER BY p.creado_en DESC, p.pedido_id DESC           -- [PERF-004] orden con desempate único
 LIMIT 100;                                            -- [PERF-003] límite real, muy por debajo de 10 000

-- ---------------------------------------------------------------------
-- 3. Escritura acotada
-- ---------------------------------------------------------------------

START TRANSACTION;                                     -- [SEC-015] unidad atómica explícita

  UPDATE tienda.pedidos
     SET estado = 'PAGADO'
   WHERE pedido_id = ?;                                -- [SEC-002][SEC-003] predicado por PK: SINGLE_ROW

  INSERT INTO tienda.pedidos (cliente_id, total, estado)
  VALUES (?, ?, 'PENDIENTE');                          -- [SEC-006] parametrizado, sin concatenación

COMMIT;

-- ---------------------------------------------------------------------
-- 4. Borrado masivo hecho correctamente
-- ---------------------------------------------------------------------

-- Paso 1: medir el alcance antes de tocar nada.
SELECT COUNT(*)
  FROM tienda.pedidos
 WHERE estado = 'CANCELADO'
   AND creado_en < '2025-01-01';

-- Paso 2: borrar por lotes, con orden determinista y dentro de transacción.
START TRANSACTION;
  DELETE FROM tienda.pedidos
   WHERE estado = 'CANCELADO'                          -- [SEC-001][SEC-003] predicado con selectividad real
     AND creado_en < '2025-01-01'
   ORDER BY pedido_id                                  -- [PERF-004] lote determinista y reanudable
   LIMIT 1000;                                         -- [PERF-014] fragmentación en lotes
COMMIT;
-- Paso 3: repetir el lote mientras ROW_COUNT() > 0.

-- ---------------------------------------------------------------------
-- 5. Consultas con NULL tratado de forma explícita
-- ---------------------------------------------------------------------

-- Paginación por clave: el acceso lo fija la PK y el resto es filtro residual.
SELECT cliente_id, email, telefono
  FROM tienda.clientes
 WHERE cliente_id > ?                                  -- [PERF-007 S2] acceso por PK
   AND telefono IS NULL                                -- [NULL-001] IS NULL, no = NULL
 ORDER BY cliente_id
 LIMIT 500;

SELECT c.cliente_id, c.email
  FROM tienda.clientes c
 WHERE NOT EXISTS (                                    -- [NULL-002] NOT EXISTS, no NOT IN
         SELECT 1 FROM tienda.pedidos p
          WHERE p.cliente_id = c.cliente_id
       )
 ORDER BY c.cliente_id
 LIMIT 500;
