# Reglas de rendimiento — `PERF-001` … `PERF-016`

Mismo formato que [security.md](security.md). `[REGLA PROPIA]` marca las violaciones definidas por el equipo.

> **Nota transversal sobre confianza:** casi toda regla de rendimiento depende de datos que
> la skill **no puede observar** (índices existentes, cardinalidad, distribución). Por eso la
> mayoría se emite con `confidence = UNVERIFIED` y **en forma condicional**, con la consulta
> exacta para confirmarla. Afirmar "falta un índice" como hecho sería inventar contexto
> (FASE 5 de [SKILL.md](../SKILL.md)).

---

## PERF-001 — `SELECT *`

- **Severidad base:** MEDIUM
- **Detección:** `SELECT *` o `SELECT t.*` en cualquier posición: consulta principal, subconsulta, CTE, `CREATE VIEW`, `INSERT … SELECT *`.
- **Condición formal:**
  ```
  IF proyección contiene * THEN severity = MEDIUM
  IF además hay JOIN                       THEN severity = HIGH
  IF además es CREATE VIEW o INSERT ... SELECT *  THEN severity = HIGH
  IF la tabla contiene columnas BLOB/TEXT (requiere schema_ddl) THEN severity = HIGH
  IF no se conoce el esquema THEN confidence = UNVERIFIED sobre el impacto exacto
  ```
- **Justificación:** cuatro problemas distintos, y solo el primero es de rendimiento. **(1)** Transfiere columnas que nadie usa, incluidos `TEXT`/`BLOB` que pueden multiplicar el volumen por órdenes de magnitud. **(2)** Impide los *covering index scans*: si la consulta pidiera solo las columnas del índice, el motor no tocaría la tabla; con `*` siempre lo hace. **(3)** Es un **riesgo de corrección, no solo de velocidad**: si alguien añade una columna, el resultado cambia de forma silenciosa y rompe el código que consume por posición, y un `INSERT … SELECT *` empieza a fallar o a insertar en la columna equivocada. **(4)** En una vista, congela la definición al momento de creación en algunos motores, produciendo divergencias entre la vista y la tabla.
- **Falsos positivos:** `SELECT COUNT(*)` no es una proyección de columnas → no aplica. `EXISTS (SELECT * FROM …)` es idiomático y el optimizador nunca materializa las columnas → INFO, no MEDIUM. Exploración manual *ad hoc* con `LIMIT` pequeño → LOW.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT * FROM usuarios u JOIN pedidos p ON p.usuario_id = u.id;
  -- DESPUÉS: proyección explícita y mínima
  SELECT u.id, u.email, p.id AS pedido_id, p.total
    FROM usuarios u
    JOIN pedidos p ON p.usuario_id = u.id;
  ```
- **Requiere contexto:** Sí, para la severidad exacta — qué columnas tiene la tabla. Consulta: `DESCRIBE usuarios;` o `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'usuarios';`

---

## PERF-002 — Ausencia de `LIMIT` en consulta potencialmente masiva

- **Severidad base:** MEDIUM
- **Detección:** `SELECT` sin `LIMIT`/`TOP`/`FETCH FIRST` **y** sin agregación que reduzca el resultado a pocas filas (`COUNT`, `SUM` sin `GROUP BY` de alta cardinalidad) **y** con `effective_predicate` distinto de `RESTRICTIVE`.
- **Condición formal:**
  ```
  IF SELECT AND NOT existe LIMIT AND NOT es agregación reductora
     AND effective_predicate != RESTRICTIVE
  THEN severity = MEDIUM
   AND blast_radius = UNKNOWN
   AND confidence = UNVERIFIED   # el volumen real depende de los datos
  IF effective_predicate IN (ABSENT, TAUTOLOGICAL) THEN severity = HIGH
  ```
- **Justificación:** sin `LIMIT`, el tamaño del resultado lo decide el volumen de la tabla, no la consulta. Una consulta que hoy devuelve 500 filas devolverá 5 millones cuando la tabla crezca, sin que nada en el código cambie — es un fallo diferido que aparece en producción y no en pruebas. El coste no es solo del motor: el resultado se materializa en memoria del cliente, y es la causa típica de agotamiento de memoria de la aplicación.
- **Falsos positivos:** consultas de agregación que devuelven una fila (`SELECT COUNT(*) FROM t`), consultas por PK (`RESTRICTIVE`), y exportaciones deliberadas por lotes (`ETL`) donde el consumo es en *streaming*. En este último caso se mantiene como LOW con nota sobre el uso de cursor.
- **Corrección:**
  ```sql
  -- Paginación estable por clave (keyset), preferible a OFFSET
  SELECT id, email, creado_en
    FROM usuarios
   WHERE creado_en < :cursor_fecha
   ORDER BY creado_en DESC, id DESC
   LIMIT 100;
  ```
- **Requiere contexto:** Sí — filas de la tabla. Consulta: `SELECT COUNT(*) FROM usuarios;`

---

## PERF-003 — `LIMIT` presente pero no acotante `[REGLA PROPIA]`

> Contramedida directa contra `SELECT * FROM TA_USERS LIMIT 1000000000;`

- **Severidad base:** HIGH
- **Detección:** existe `LIMIT`/`TOP`/`FETCH FIRST` con valor literal **mayor que `LIMIT_MAX_ACCEPTABLE` (10 000)**. También `LIMIT 18446744073709551615` (el idioma de MySQL para "sin límite" cuando se usa `OFFSET`), y `LIMIT` con valor procedente de variable no acotada.
- **Condición formal:**
  ```
  IF existe LIMIT AND LIMIT.valor > LIMIT_MAX_ACCEPTABLE
  THEN blast_radius = UNBOUNDED
   AND severity = HIGH
   AND PROHIBIDO tratar la presencia de LIMIT como mitigación de PERF-002
  IF LIMIT.valor procede de una variable sin cota conocida
  THEN confidence = UNVERIFIED AND severity = MEDIUM
  ```
- **Justificación:** un `LIMIT` es una mitigación **solo si su valor acota el resultado a algo que el cliente puede manejar**. `LIMIT 1000000000` no acota nada: para cualquier tabla real el plan de ejecución es idéntico al de la consulta sin `LIMIT`, y el motor lo descarta como restricción. Su único efecto práctico es **satisfacer un control que comprueba la presencia de la cláusula** — por eso esta regla existe: cualquier verificación basada en presencia de `LIMIT` es evadible escribiendo un número grande. El umbral de 10 000 marca la frontera entre "resultado que un cliente consume" y "volcado de tabla".
- **Falsos positivos:** procesos de exportación que iteran con `LIMIT … OFFSET` grandes de forma deliberada → sigue siendo un hallazgo, pero se anota como MEDIUM si el `OFFSET` demuestra paginación real. `LIMIT 100000` en un job nocturno de generación de informes con consumo en *streaming* → MEDIUM con nota.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT * FROM TA_USERS LIMIT 1000000000;
  -- DESPUÉS: proyección explícita, orden determinista y límite real
  SELECT FCUSERID, FCEMAIL, FCESTADO
    FROM TA_USERS
   ORDER BY FCUSERID
   LIMIT 100;
  -- Si de verdad se necesita todo el conjunto, paginar por clave:
  SELECT FCUSERID, FCEMAIL FROM TA_USERS
   WHERE FCUSERID > :ultimo_id ORDER BY FCUSERID LIMIT 1000;
  ```
- **Requiere contexto:** No. La regla se resuelve comparando el literal con la constante.

---

## PERF-004 — `LIMIT` sin `ORDER BY`

- **Severidad base:** MEDIUM
- **Detección:** existe `LIMIT`/`TOP`/`FETCH FIRST` y no existe `ORDER BY` en el mismo nivel de consulta.
- **Condición formal:**
  ```
  IF existe LIMIT AND NOT existe ORDER BY
  THEN severity = MEDIUM
   AND nota = "el conjunto devuelto no es determinista entre ejecuciones"
  IF se usa junto con OFFSET THEN severity = HIGH   # paginación con filas repetidas u omitidas
  ```
- **Justificación:** sin `ORDER BY`, el estándar SQL **no garantiza ningún orden**, así que "las primeras 10 filas" no es un concepto definido: el motor devuelve las que le convenga según el plan, y el plan cambia con las estadísticas, con la versión o con el paralelismo. La consecuencia grave aparece con paginación: `LIMIT 10 OFFSET 0` y `LIMIT 10 OFFSET 10` pueden solaparse o saltarse filas, de modo que un listado paginado muestra registros duplicados y **omite otros sin error alguno**. Es un defecto de corrección disfrazado de detalle de rendimiento.
- **Falsos positivos:** `SELECT 1 FROM t WHERE … LIMIT 1` usado como prueba de existencia → INFO, el orden es irrelevante. `LIMIT 1` sobre una consulta con predicado por clave única → INFO.
- **Corrección:**
  ```sql
  -- El ORDER BY debe incluir un desempate único (la PK) para ser estable
  SELECT id, email FROM usuarios ORDER BY creado_en DESC, id DESC LIMIT 10;
  ```
- **Requiere contexto:** No.

---

## PERF-005 — Predicado no sargable (función sobre la columna)

- **Severidad base:** HIGH
- **Detección:** en `WHERE`/`JOIN`/`HAVING`, la columna aparece dentro de una función o de una expresión aritmética: `YEAR(fecha) = 2024`, `UPPER(email) = 'A@B.C'`, `SUBSTR(codigo,1,3) = 'ABC'`, `precio * 1.21 > 100`, `CAST(id AS CHAR) = '5'`, `DATE(creado_en) = CURRENT_DATE`.
- **Condición formal:**
  ```
  IF una columna aparece envuelta en función o expresión dentro de un predicado
  THEN severity = HIGH
   AND confidence = UNVERIFIED (el impacto depende de si existe índice)
   AND fix = reescritura sargable
  ```
- **Justificación:** un índice B-tree almacena los valores de la columna, no el resultado de aplicarles una función. Si el predicado es `YEAR(fecha) = 2024`, el motor no puede localizar entradas en el índice porque no sabe qué valores de `fecha` producen `2024`: debe leer **todas** las filas y evaluar la función en cada una. El resultado es un *full scan* con coste añadido por llamada de función, y lo peor es que el plan degrada de forma abrupta —de acceso por índice a recorrido completo— por un cambio de escritura que parece inocuo. La reescritura a rango (`>=` … `<`) conserva el mismo resultado y permite el acceso por índice.
- **Falsos positivos:** si existe un **índice basado en expresión** (PostgreSQL: `CREATE INDEX ON t (YEAR(fecha))`; Oracle: índice funcional) el predicado sí es sargable. Como la skill no ve los índices, el hallazgo se emite `UNVERIFIED` y en condicional. Si `existing_indexes` demuestra el índice funcional, la regla no se dispara.
- **Corrección:**
  ```sql
  -- ANTES (no sargable)
  SELECT id FROM pedidos WHERE YEAR(creado_en) = 2024;
  -- DESPUÉS (sargable: rango semiabierto, evita problemas de hora y de bisiestos)
  SELECT id FROM pedidos
   WHERE creado_en >= '2024-01-01' AND creado_en < '2025-01-01';

  -- ANTES
  SELECT id FROM usuarios WHERE UPPER(email) = 'A@B.COM';
  -- DESPUÉS: normalizar al escribir, o usar collation insensible a mayúsculas
  SELECT id FROM usuarios WHERE email = 'a@b.com';
  ```
- **Requiere contexto:** Sí — índices existentes. Consulta: `SHOW INDEX FROM pedidos;` / `SELECT indexdef FROM pg_indexes WHERE tablename = 'pedidos';`

---

## PERF-006 — `LIKE` con comodín inicial

- **Severidad base:** MEDIUM
- **Detección:** patrón `LIKE '%…'` o `LIKE '%…%'`, incluido con concatenación (`LIKE '%' || :p || '%'`, `LIKE CONCAT('%', ?, '%')`).
- **Condición formal:**
  ```
  IF patrón LIKE empieza por % THEN severity = MEDIUM AND confidence = UNVERIFIED
  IF el patrón es exactamente '%' o '%%' THEN NO es PERF-006: es SEC-003 (tautológico)
  ```
- **Justificación:** un índice B-tree ordena por prefijo, así que solo puede resolver búsquedas cuyo prefijo sea conocido. Con `'%texto'` el prefijo es desconocido y el índice queda inservible: el motor recorre toda la tabla comparando cadena por cadena. El coste crece linealmente con la tabla, y el patrón es especialmente frecuente en buscadores construidos "a mano" que funcionan bien en desarrollo y colapsan en producción.
- **Falsos positivos:** tablas pequeñas y estables (catálogos de decenas de filas) → LOW. Búsquedas sobre columnas ya cubiertas por un índice *full-text* → no aplica si `existing_indexes` lo demuestra.
- **Corrección:**
  ```sql
  -- Si se necesita búsqueda por subcadena, usar el índice adecuado, no LIKE:
  -- MySQL / PostgreSQL:
  SELECT id, nombre FROM productos WHERE MATCH(nombre) AGAINST (:termino IN BOOLEAN MODE);
  -- PostgreSQL con trigramas:
  CREATE INDEX idx_productos_nombre_trgm ON productos USING gin (nombre gin_trgm_ops);
  -- Si basta con prefijo, el índice sí sirve:
  SELECT id, nombre FROM productos WHERE nombre LIKE :termino || '%';
  ```
- **Requiere contexto:** Sí — tamaño de la tabla e índices de texto disponibles.

---

## PERF-007 — Índice potencialmente faltante

> Regla de **emisión siempre condicional**. Nunca afirma que falta un índice.

- **Severidad base:** MEDIUM
- **Detección:** columnas que aparecen en `WHERE`, `JOIN … ON`, `ORDER BY` o `GROUP BY` y que no son, de forma demostrable a partir de la entrada, clave primaria o parte de un índice declarado en el script o en `existing_indexes`.
- **Condición formal:**
  ```
  IF columna usada en WHERE/JOIN/ORDER BY/GROUP BY
     AND NOT (columna es PK/UNIQUE declarada en la entrada)
     AND NOT (existe CREATE INDEX sobre ella en el mismo script)
     AND NOT (existing_indexes la incluye)
  THEN severity = MEDIUM
   AND confidence = UNVERIFIED                       # SIEMPRE
   AND redacción OBLIGATORIAMENTE condicional:
       "si no existe índice sobre (col), este predicado provoca recorrido completo"
   AND añadir a "Información faltante" la consulta para comprobarlo
   AND PROHIBIDO afirmar "falta un índice en X"
  # Supresiones introducidas en v1.1 tras test-01:
  S1. IF el CREATE INDEX correspondiente está en el mismo script
         OR el predicado usa la PK/UNIQUE declarada en el mismo script
      THEN NO emitir el hallazgo
  S2. IF el predicado es una conjunción (AND) y al menos un operando usa una
         columna indexada, PK o UNIQUE demostrable en la entrada
      THEN NO emitir PERF-007 sobre los operandos restantes de esa conjunción
      # Son filtros residuales: el método de acceso ya lo fija el operando indexado
      # y un índice adicional sobre ellos no cambiaría el plan. Emitirlo sería ruido.
  ```
- **Justificación:** la ausencia de un índice **no es observable desde el texto de la consulta**. Afirmarla sería exactamente el tipo de invención de contexto que la skill prohíbe, y además es contraproducente: crear índices "por si acaso" degrada la escritura, ocupa espacio y confunde al optimizador. Lo que sí es verificable desde el texto es que *el predicado se beneficiaría de un índice si no existiera*, y esa es la afirmación condicional que la regla emite. La supresión de v1.1 evita el ruido que hacía fallar el *happy path*: si el propio script crea el índice, señalarlo es un falso positivo puro.
- **Falsos positivos:** tablas muy pequeñas donde el recorrido completo es más rápido que el índice; columnas de baja cardinalidad donde el índice no aporta (ver PERF-016); índices que existen pero no están en la entrada — motivo por el que el hallazgo es siempre `UNVERIFIED`.
- **Corrección:**
  ```sql
  -- 1. COMPROBAR primero (no crear a ciegas)
  SHOW INDEX FROM pedidos;                                    -- MySQL
  SELECT indexname, indexdef FROM pg_indexes WHERE tablename='pedidos';  -- PostgreSQL
  EXPLAIN SELECT id FROM pedidos WHERE cliente_id = 42;       -- ver el plan real
  -- 2. Solo si se confirma el recorrido completo:
  CREATE INDEX idx_pedidos_cliente_id ON pedidos (cliente_id);
  -- Índice compuesto: el orden importa, primero igualdad y luego rango
  CREATE INDEX idx_pedidos_cliente_fecha ON pedidos (cliente_id, creado_en);
  ```
- **Requiere contexto:** **Sí, siempre.** Consultas indicadas arriba.

---

## PERF-008 — `JOIN` sin condición (producto cartesiano)

- **Severidad base:** HIGH
- **Detección:** `JOIN` sin `ON`/`USING`; `CROSS JOIN` no declarado como intencional; sintaxis antigua `FROM a, b` sin la condición de unión correspondiente en el `WHERE`; `ON` que compara constantes en lugar de columnas (`ON 1=1`).
- **Condición formal:**
  ```
  IF JOIN carece de condición de unión efectiva
  THEN severity = HIGH
   AND blast_radius = UNBOUNDED
   AND nota = "el resultado es el producto de las cardinalidades"
  IF el statement es UPDATE/DELETE multi-tabla con JOIN sin condición
  THEN severity = CRITICAL      # afecta a todas las filas de la tabla objetivo
  ```
- **Justificación:** un producto cartesiano genera `N × M` filas. Con dos tablas de 10 000 filas el resultado son 100 millones de filas: no es una consulta lenta, es una consulta que no termina y que consume el disco temporal del servidor, afectando a todas las demás sesiones. Cuando la sintaxis es la antigua `FROM a, b`, la omisión de la condición es un error de escritura habitual y difícil de ver en consultas largas. En un `UPDATE`/`DELETE` multi-tabla el efecto sube a CRITICAL porque cada fila de la tabla objetivo encuentra al menos una pareja y acaba modificada.
- **Falsos positivos:** `CROSS JOIN` deliberado contra una tabla de calendario o de series generadas para rellenar huecos en informes → legítimo; se reporta como INFO si una de las relaciones es demostrablemente pequeña o generada (`generate_series`, tabla de dígitos).
- **Corrección:**
  ```sql
  -- ANTES
  SELECT u.id, p.id FROM usuarios u, pedidos p;
  -- DESPUÉS
  SELECT u.id, p.id
    FROM usuarios u
    JOIN pedidos p ON p.usuario_id = u.id;
  ```
- **Requiere contexto:** No, la ausencia de condición es visible en el texto.

---

## PERF-009 — Subconsulta correlacionada en la lista de proyección

- **Severidad base:** MEDIUM
- **Detección:** subconsulta en el `SELECT` que referencia una columna de la consulta externa.
- **Condición formal:**
  ```
  IF existe subconsulta en la lista de proyección que referencia la consulta externa
  THEN severity = MEDIUM
   AND si además la consulta externa no tiene LIMIT -> severity = HIGH
  ```
- **Justificación:** la subconsulta se evalúa **una vez por cada fila** del resultado externo. Es el equivalente dentro del motor del problema N+1 de los ORMs: una consulta que devuelve 10 000 filas ejecuta 10 000 subconsultas. Algunos optimizadores modernos consiguen transformarla en un *join*, pero no siempre —depende de si hay agregación, de la nulabilidad y de la versión—, así que el rendimiento pasa a depender de un detalle del optimizador en lugar de la escritura de la consulta.
- **Falsos positivos:** subconsulta correlacionada sobre un resultado externo de una sola fila → INFO. Motores que demuestran la descorrelación en el `EXPLAIN` → si se aporta el plan, no se emite.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT u.id, (SELECT COUNT(*) FROM pedidos p WHERE p.usuario_id = u.id) AS n_pedidos
    FROM usuarios u;
  -- DESPUÉS: una sola pasada con agregación
  SELECT u.id, COALESCE(p.n_pedidos, 0) AS n_pedidos
    FROM usuarios u
    LEFT JOIN (SELECT usuario_id, COUNT(*) AS n_pedidos
                 FROM pedidos GROUP BY usuario_id) p
      ON p.usuario_id = u.id;
  ```
- **Requiere contexto:** No.

---

## PERF-010 — `DISTINCT` que enmascara un `JOIN` incorrecto

- **Severidad base:** MEDIUM
- **Detección:** `SELECT DISTINCT` en una consulta con `JOIN` y sin agregación.
- **Condición formal:**
  ```
  IF existe DISTINCT AND existe JOIN AND NOT existe GROUP BY
  THEN severity = MEDIUM
   AND nota = "verificar si el DISTINCT compensa una duplicación producida por el JOIN"
  ```
- **Justificación:** el `DISTINCT` obliga a materializar y ordenar (o construir una tabla hash de) todo el resultado intermedio antes de deduplicar, de modo que el coste se paga sobre las filas duplicadas que no debían haberse generado. Pero el problema de fondo es de corrección: si el `JOIN` duplica filas es porque la relación es 1:N y falta un criterio; el `DISTINCT` oculta el síntoma y, en el momento en que se añada una columna a la proyección que sí difiera entre duplicados, las filas duplicadas reaparecerán y el error se manifestará como datos incorrectos.
- **Falsos positivos:** `DISTINCT` legítimo sobre una unión de conjuntos donde la duplicación es esperada y deseada eliminar → LOW.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT DISTINCT u.id, u.email
    FROM usuarios u JOIN pedidos p ON p.usuario_id = u.id;
  -- DESPUÉS: expresar la intención real ("usuarios que tienen al menos un pedido")
  SELECT u.id, u.email
    FROM usuarios u
   WHERE EXISTS (SELECT 1 FROM pedidos p WHERE p.usuario_id = u.id);
  ```
- **Requiere contexto:** No.

---

## PERF-011 — `OR` sobre columnas distintas

- **Severidad base:** LOW
- **Detección:** predicado `OR` cuyos operandos referencian columnas diferentes: `WHERE email = :x OR telefono = :y`.
- **Condición formal:**
  ```
  IF WHERE contiene OR entre columnas distintas
  THEN severity = LOW
   AND confidence = UNVERIFIED
  IF alguna de las ramas no tiene índice posible THEN severity = MEDIUM
  ```
- **Justificación:** un único índice B-tree no puede satisfacer las dos ramas de una disyunción sobre columnas distintas. Algunos motores aplican *index merge* (unión de dos accesos por índice), pero es una optimización frágil que el planificador descarta con facilidad si las estadísticas sugieren baja selectividad; cuando la descarta, el plan pasa a recorrido completo. Reescribir con `UNION ALL` hace explícito el acceso por cada índice y elimina la dependencia de esa heurística.
- **Falsos positivos:** disyunciones sobre la misma columna (`estado = 'A' OR estado = 'B'`) → no aplica; equivalen a `IN` y sí usan índice.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT id FROM usuarios WHERE email = :e OR telefono = :t;
  -- DESPUÉS
  SELECT id FROM usuarios WHERE email = :e
  UNION
  SELECT id FROM usuarios WHERE telefono = :t;
  ```
- **Requiere contexto:** Sí — índices existentes.

---

## PERF-012 — Comparación entre tipos incompatibles (conversión implícita) `[REGLA PROPIA]`

- **Severidad base:** HIGH
- **Detección:** comparación entre una columna y un literal de tipo distinto: columna numérica con literal entrecomillado (`WHERE id = '42'`), columna de texto con literal numérico (`WHERE codigo = 42`), fecha comparada con cadena en formato no ISO, `JOIN` entre columnas de tipos diferentes (`ON a.id_varchar = b.id_int`).
- **Condición formal:**
  ```
  IF se compara una columna con un valor de tipo distinto
  THEN severity = HIGH
   AND confidence = UNVERIFIED si no se aporta schema_ddl
   AND nota = "riesgo doble: índice inutilizado y posible resultado incorrecto"
  IF ocurre en la condición de un JOIN THEN severity = HIGH y añadir impacto de plan
  ```
- **Justificación:** dos consecuencias, y la segunda es la grave. **(1)** Rendimiento: para comparar, el motor convierte uno de los operandos; si convierte la **columna**, el índice deja de ser aplicable (es el caso de MySQL al comparar `VARCHAR` con número, donde convierte la columna a número). **(2)** Corrección: las reglas de conversión no son intuitivas y **cambian el conjunto de filas devuelto**. En MySQL, `WHERE codigo_varchar = 0` es cierto para toda fila cuyo texto no empiece por dígito, porque `'abc'` se convierte a `0` — una comparación que parece un filtro devuelve casi toda la tabla. En el caso inverso, `'00123'` y `123` comparan iguales como números pero distintos como texto, así que el mismo código produce resultados diferentes según el tipo declarado. Es un fallo silencioso: no hay error, hay datos equivocados.
- **Falsos positivos:** motores estrictos (PostgreSQL) que rechazan la comparación con error en lugar de convertir → el hallazgo baja a MEDIUM porque el fallo es ruidoso y se detecta al primer intento.
- **Corrección:**
  ```sql
  -- ANTES:  WHERE user_id = '00123'      (user_id es INT)
  -- DESPUÉS
  SELECT id FROM sesiones WHERE user_id = 123;
  -- Si la columna es realmente de texto, comparar como texto y unificar el tipo del JOIN:
  ALTER TABLE sesiones MODIFY user_id BIGINT NOT NULL;   -- previa migración de datos
  ```
- **Requiere contexto:** Sí — el tipo declarado de la columna. Consulta: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'sesiones';`
- **Divergencia motor:** MySQL y SQLite convierten de forma implícita y silenciosa; PostgreSQL y SQL Server son más estrictos y suelen fallar o convertir el literal, no la columna.

---

## PERF-013 — Ordenación costosa o no indexable

- **Severidad base:** HIGH para `ORDER BY RAND()`, MEDIUM en el resto
- **Detección:** `ORDER BY RAND()` / `NEWID()` / `RANDOM()`; `ORDER BY` sobre una expresión o función; `ORDER BY` por posición ordinal (`ORDER BY 3`); `ORDER BY` sobre columna distinta de las del índice usado por el `WHERE`.
- **Condición formal:**
  ```
  IF ORDER BY contiene RAND()/RANDOM()/NEWID() THEN severity = HIGH
  IF ORDER BY contiene una expresión o función  THEN severity = MEDIUM
  IF ORDER BY usa posición ordinal              THEN severity = LOW  (frágil ante cambios en la proyección)
  ```
- **Justificación:** `ORDER BY RAND()` obliga a **generar un valor aleatorio para cada fila de la tabla, materializar el conjunto completo y ordenarlo**, incluso cuando solo se quiere una fila; ningún índice puede ayudar porque el criterio de orden no existe hasta la ejecución. Es el patrón habitual de "dame un registro al azar" y su coste es lineal en la tabla, no constante. `ORDER BY` por posición ordinal no es un problema de rendimiento sino de mantenimiento: añadir una columna a la proyección cambia silenciosamente el criterio de ordenación.
- **Falsos positivos:** tablas de decenas de filas (catálogos) → LOW.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT id FROM productos ORDER BY RAND() LIMIT 1;
  -- DESPUÉS: elegir por clave, con coste constante
  SELECT id FROM productos
   WHERE id >= FLOOR(RAND() * (SELECT MAX(id) FROM productos))
   ORDER BY id LIMIT 1;
  ```
- **Requiere contexto:** Sí — tamaño de la tabla, para calibrar el impacto.

---

## PERF-014 — DML masivo sin fragmentación por lotes

- **Severidad base:** MEDIUM
- **Detección:** `UPDATE`/`DELETE`/`INSERT … SELECT` con `blast_radius` en `UNBOUNDED`, `UNKNOWN` o `WHOLE_TABLE` y sin `LIMIT` por lote ni bucle de fragmentación.
- **Condición formal:**
  ```
  IF DML destructivo AND blast_radius IN (UNKNOWN, UNBOUNDED, WHOLE_TABLE)
     AND NOT existe LIMIT por lote
  THEN severity = MEDIUM
   AND si touches_sensitive = true -> aplicar E5 -> mínimo HIGH
  ```
- **Justificación:** una transacción que modifica millones de filas mantiene bloqueos durante todo su tiempo de ejecución, hace crecer el *undo/redo* de forma proporcional y, en topologías con réplicas, genera un único evento enorme que la réplica aplica en serie, produciendo un retraso que puede alcanzar horas. Además, si falla al final, el `ROLLBACK` tarda tanto o más que la operación original. Fragmentar en lotes de `BATCH_SIZE_RECOMMENDED` convierte un riesgo de indisponibilidad en una operación interrumpible y reanudable.
- **Falsos positivos:** ventanas de mantenimiento planificadas con la base fuera de servicio → se mantiene como LOW si `purpose` lo declara.
- **Corrección:**
  ```sql
  -- Bucle de lotes: repetir hasta que no afecte filas
  START TRANSACTION;
  UPDATE pedidos SET estado = 'ARCHIVADO'
   WHERE estado = 'CERRADO' AND creado_en < '2023-01-01'
   LIMIT 1000;
  COMMIT;
  -- comprobar ROW_COUNT() y repetir mientras sea > 0
  ```
- **Requiere contexto:** Sí — filas afectadas. Consulta: `SELECT COUNT(*) FROM pedidos WHERE <predicado>;`

---

## PERF-015 — Agregación sobre tabla completa sin filtro

- **Severidad base:** LOW
- **Detección:** `COUNT(*)`, `SUM`, `AVG`, `MAX` sin `WHERE` restrictivo y sin `GROUP BY` acotado.
- **Condición formal:**
  ```
  IF agregación AND effective_predicate IN (ABSENT, TAUTOLOGICAL, NON_RESTRICTIVE)
  THEN severity = LOW
   AND confidence = UNVERIFIED
   AND si aparece dentro de una vista o de una subconsulta correlacionada -> MEDIUM
  # Precisión añadida en v1.1 (test-01): un COUNT(*) con predicado RESTRICTIVE o
  # RESTRICTIVE_UNKNOWN NO se reporta. Es justamente la verificación previa que
  # las correcciones de SEC-001/SEC-003 exigen; penalizarla sería contradictorio.
  ```
- **Justificación:** `COUNT(*)` sin filtro obliga a recorrer la tabla o, en el mejor caso, un índice completo. En InnoDB no existe un contador exacto mantenido, y en PostgreSQL el recuento depende de la visibilidad MVCC de cada fila, por lo que tampoco puede resolverse por metadatos. El coste es aceptable en un informe puntual y problemático cuando está en la ruta de una petición web, que es donde suele acabar (paginadores que muestran "página 1 de N"). El impacto real depende del volumen, dato que la skill no conoce.
- **Falsos positivos:** informes nocturnos, comprobaciones puntuales, tablas pequeñas → INFO.
- **Corrección:**
  ```sql
  -- Para paginadores, evitar el conteo exacto:
  SELECT id FROM pedidos ORDER BY id LIMIT 101;  -- 101 => "más de 100 resultados"
  -- Para métricas frecuentes, contador mantenido o estimación de las estadísticas:
  SELECT reltuples::bigint AS aprox FROM pg_class WHERE relname = 'pedidos';
  ```
- **Requiere contexto:** Sí — volumen de la tabla.

---

## PERF-016 — Índice inútil, redundante o contraproducente

- **Severidad base:** LOW
- **Detección:** en sentencias `CREATE INDEX`: índice sobre columna booleana o de muy baja cardinalidad declarada (`activo`, `borrado`, `sexo`); índice cuyo prefijo de columnas ya está cubierto por otro índice del mismo script (`(a)` cuando existe `(a,b)`); índice sobre una columna que ya es PK; más de 5 índices sobre la misma tabla en el mismo script.
- **Condición formal:**
  ```
  IF CREATE INDEX sobre columna de baja cardinalidad conocida THEN severity = LOW
  IF el conjunto de columnas es prefijo de otro índice existente en el script THEN severity = LOW (redundante)
  IF índice sobre la PK THEN severity = LOW (duplicado del índice agrupado)
  ```
- **Justificación:** un índice no es gratis: cada `INSERT`, `UPDATE` y `DELETE` debe mantenerlo, ocupa espacio y aumenta el trabajo del optimizador. Sobre una columna booleana el índice apenas discrimina —la mitad de la tabla por valor—, así que el planificador lo descarta y solo queda el coste de mantenimiento. Un índice `(a)` cuando existe `(a,b)` es redundante porque el compuesto ya sirve para cualquier consulta que filtre por `a`, dado que el prefijo izquierdo es utilizable. Añadir índices "por si acaso" es tan perjudicial como no tenerlos, y por eso PERF-007 exige comprobar antes de crear.
- **Falsos positivos:** índice parcial o filtrado sobre columna booleana (`WHERE activo = TRUE` en PostgreSQL/SQL Server) → sí es útil y no se reporta si la sintaxis del filtro está presente. Índice sobre booleano en tabla con distribución muy sesgada (99/1) → puede ser útil; se emite como INFO si `table_stats` lo demuestra.
- **Corrección:**
  ```sql
  -- ANTES
  CREATE INDEX idx_usuarios_activo ON usuarios (activo);
  -- DESPUÉS: índice parcial (solo las filas que se consultan)
  CREATE INDEX idx_usuarios_activos ON usuarios (creado_en) WHERE activo = TRUE;  -- PostgreSQL
  -- O compuesto que empiece por la columna selectiva
  CREATE INDEX idx_usuarios_email_activo ON usuarios (email, activo);
  ```
- **Requiere contexto:** Sí — cardinalidad real e índices existentes. Consulta: `SELECT COUNT(DISTINCT activo) FROM usuarios;`
