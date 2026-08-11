-- =====================================================================
-- examples/invalid.sql
-- Entrada con violaciones evidentes y múltiples.
-- Resultado esperado de la skill: BLOCK — NO EJECUTAR.
-- Dialecto: MySQL 8.0.
--
-- Cada statement lleva anotada la regla que DEBE dispararse. Se usa en
-- tests/test-02.md (error evidente).
--
-- ADVERTENCIA: este archivo es material de prueba. No ejecutar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. DDL defectuoso
-- ---------------------------------------------------------------------

-- [CONV-007] sin PRIMARY KEY
-- [CONV-004] `order` y `date` son palabras reservadas
-- [TYPE-002] importe en FLOAT
-- [TYPE-003] fecha en VARCHAR
-- [TYPE-001] VARCHAR(4000) para un código postal
-- [TYPE-004] booleano como CHAR(1) sin CHECK
-- [NULL-006] columnas obligatorias sin NOT NULL ni DEFAULT
-- [CONV-008] cliente_id sin FOREIGN KEY
-- [CONV-006] sin esquema calificado
CREATE TABLE `order` (
  id            INT,
  cliente_id    INT,
  total         FLOAT,
  `date`        VARCHAR(20),
  codigo_postal VARCHAR(4000),
  activo        CHAR(1)
);

-- ---------------------------------------------------------------------
-- 2. Consultas
-- ---------------------------------------------------------------------

-- [PERF-001] SELECT * con JOIN  ->  HIGH
-- [PERF-008] sintaxis antigua sin condición de unión: producto cartesiano
-- [CONV-001] alias e identificadores no descriptivos
-- [CONV-005] columnas sin calificar
-- [PERF-002] sin LIMIT
SELECT *
  FROM t1 a, t2 b;

-- [PERF-005] función sobre la columna: predicado no sargable
-- [PERF-006] LIKE con comodín inicial
-- [PERF-001] SELECT *
-- [PERF-002] sin LIMIT
SELECT *
  FROM pedidos
 WHERE YEAR(creado_en) = 2024
   AND descripcion LIKE '%oferta%';

-- [NULL-001] comparación de igualdad con NULL: nunca devuelve filas
SELECT id
  FROM usuarios
 WHERE fecha_baja = NULL;

-- [NULL-002] NOT IN sobre subconsulta con columna nullable
-- [PERF-002] sin LIMIT
SELECT id
  FROM usuarios
 WHERE id NOT IN (SELECT usuario_id FROM pedidos);

-- [PERF-013] ORDER BY RAND(): materializa y ordena la tabla completa
SELECT id
  FROM productos
 ORDER BY RAND()
 LIMIT 1;

-- ---------------------------------------------------------------------
-- 3. Escritura destructiva
-- ---------------------------------------------------------------------

-- [SEC-002] UPDATE sin WHERE  ->  CRITICAL
-- [SEC-007] escribe sobre columna de privilegio (E2)
UPDATE usuarios
   SET rol = 'ADMIN';

-- [SEC-001] DELETE sin WHERE  ->  CRITICAL
DELETE FROM pedidos;

-- [SEC-005] TRUNCATE: irreversible, no dispara triggers, reinicia el contador
TRUNCATE TABLE auditoria;

-- [SEC-004] DROP de tabla  ->  CRITICAL, IRREVERSIBLE
DROP TABLE clientes_historico;

-- [SEC-014] el DELETE depende de una subconsulta sin filtro propio:
--           si la integridad referencial es correcta, borra la tabla entera
DELETE FROM pedidos
 WHERE cliente_id IN (SELECT id FROM clientes);

-- [SEC-006] concatenación de una variable de aplicación  ->  inyección SQL
-- (fragmento tal y como aparece en el código de la aplicación)
-- "SELECT * FROM usuarios WHERE email = '" + emailUsuario + "'"
SELECT * FROM usuarios WHERE email = '" + emailUsuario + "';

-- [SEC-012] concesión de privilegios sin ámbito ni origen acotados
GRANT ALL PRIVILEGES ON *.* TO 'app'@'%';

-- [SEC-015] el script acumula múltiples statements destructivos sin
--           ninguna transacción explícita  ->  escalado E3
