# Reglas de convenciones, NULL y tipos de datos

Tres familias en un mismo archivo por compartir la naturaleza de "corrección estructural del modelo":

| Familia | Rango | Cubre |
|---|---|---|
| `CONV` | CONV-001 … CONV-008 | Nombres, convenciones de escritura y estructura del DDL |
| `NULL` | NULL-001 … NULL-007 | Lógica trivaluada y uso incorrecto de `NULL` |
| `TYPE` | TYPE-001 … TYPE-009 | Elección de tipos de datos |

Mismo formato que [security.md](security.md). `[REGLA PROPIA]` marca las violaciones definidas por el equipo.

---

# CONV — Nombres y convenciones

## CONV-001 — Identificador no descriptivo

- **Severidad base:** LOW
- **Detección:** identificador (tabla, columna, índice, alias de CTE) que cumple alguno de:
  - longitud ≤ 2 y no es un alias de tabla en una consulta de ≤ 2 tablas;
  - coincide con `/^(tabla|table|datos|data|info|temp|tmp|test|aux|x|y|z|col|campo|valor)\d*$/i`;
  - es una secuencia numerada sin semántica: `t1`, `t2`, `col1`, `campo3`, `a1`;
  - es un nombre genérico sin dominio: `datos`, `registro`, `elemento`.
- **Condición formal:**
  ```
  IF identificador coincide con el patrón de no-descriptivo
  THEN severity = LOW
  IF es un nombre de TABLA o de COLUMNA (persistente) THEN severity = MEDIUM
  IF es un ALIAS local de una consulta corta          THEN severity = INFO
  ```
- **Justificación:** un nombre de tabla o columna es la única documentación que sobrevive al código: persiste en la base de datos durante años y aparece en cada consulta, informe y volcado. `t1` obliga a cada lector a reconstruir su significado desde el contexto, y cuando el contexto se pierde —el autor cambia de equipo— el coste de renombrar ya es prohibitivo porque la aplicación depende del nombre. Por eso la severidad distingue entre lo persistente (MEDIUM) y lo local (INFO): un alias `u` para `usuarios` dentro de una consulta de cinco líneas es legible y convencional; una columna llamada `campo3` no lo es nunca.
- **Falsos positivos:** alias cortos convencionales y consistentes (`u` para `usuarios`, `p` para `pedidos`) en consultas legibles → INFO. Sufijos numéricos con significado real (`telefono_2` como segundo teléfono) → no aplica.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT a.c1, b.c2 FROM t1 a, t2 b WHERE a.id = b.id;
  -- DESPUÉS
  SELECT u.email, p.total
    FROM usuarios u
    JOIN pedidos  p ON p.usuario_id = u.id;
  ```
- **Requiere contexto:** No.

---

## CONV-002 — Prefijos y notación húngara heredada

- **Severidad base:** INFO
- **Detección:** prefijos sistemáticos de tipo o de categoría: `TA_`/`TB_` en tablas, `FC`/`FN`/`FD` en columnas (texto/numérico/fecha), `tbl`, `str`, `int`, `sp_`, `usp_`, `fn_`.
- **Condición formal:**
  ```
  IF existe un prefijo sistemático AND se aplica de forma consistente en toda la entrada
  THEN severity = INFO
   AND nota = "convención heredada; se respeta si el estándar del proyecto la exige"
  IF el prefijo se aplica de forma INCONSISTENTE dentro de la misma entrada
  THEN severity = LOW    # la inconsistencia sí es un defecto verificable
  ```
- **Justificación (decisión deliberada del equipo):** la notación húngara en base de datos tiene un problema real —codifica el tipo en el nombre, de modo que cambiar `VARCHAR` por `DATE` obliga a renombrar la columna o a convivir con un nombre que miente— pero **es una convención, no un defecto verificable**, y muchos sistemas heredados (Genexus, AS/400, ERPs) la imponen. Marcar como error algo que el estándar del proyecto exige generaría ruido en cada revisión y erosionaría la credibilidad del resto de hallazgos, que es el activo más frágil de un revisor automático. Lo que sí es verificable sin conocer el estándar es la **inconsistencia interna**: si en el mismo script conviven `FCEMAIL` y `email`, alguien se equivocó, y eso sí se reporta. Esta decisión es también la razón por la que los ejemplos del enunciado (`TA_USERS`, `FCROLE`) no generan hallazgos de nombre en nuestro reporte: los hallazgos que emitimos sobre ellos son de seguridad, que es donde está el riesgo real.
- **Falsos positivos:** por diseño la regla es INFO precisamente para no producirlos.
- **Corrección:** ninguna obligatoria. Si el proyecto adopta un estándar nuevo, migrar de forma completa, nunca parcial.
- **Requiere contexto:** Sí — el estándar de nomenclatura del proyecto. Si no se aporta, la regla se queda en INFO y **no se asume** ninguno.

---

## CONV-003 — Mezcla de convenciones de escritura

- **Severidad base:** LOW
- **Detección:** en la misma entrada conviven ≥2 estilos de identificador: `snake_case`, `camelCase`, `PascalCase`, `MAYÚSCULAS`; o mezcla de idiomas (`usuario` junto a `orders`); o palabras clave SQL escritas de forma inconsistente (`select` y `SELECT`).
- **Condición formal:**
  ```
  IF count(estilos de identificador distintos en la entrada) >= 2
  THEN severity = LOW
   AND listar los identificadores de cada estilo como evidencia
  IF la mezcla es de IDIOMA en nombres persistentes THEN severity = LOW y nota específica
  ```
- **Justificación:** el coste no es estético sino de escritura de consultas: en motores con *identifiers* sensibles a mayúsculas (PostgreSQL cuando se crean entrecomillados, MySQL en Linux según `lower_case_table_names`) la mezcla obliga a recordar cómo se escribió cada objeto y produce errores "objeto no existe" que solo aparecen al desplegar en otro sistema operativo. La mezcla de idiomas multiplica el problema porque además obliga a recordar en qué idioma se nombró cada concepto.
- **Falsos positivos:** convenciones distintas y **justificadas** por capa (tablas de negocio en español, tablas técnicas de una librería en inglés) → INFO si la separación es sistemática.
- **Corrección:** fijar un estándar único y aplicarlo. Recomendación por defecto: `snake_case` en minúsculas para identificadores, palabras clave en mayúsculas, un solo idioma.
- **Requiere contexto:** No.

---

## CONV-004 — Palabra reservada usada como identificador `[REGLA PROPIA]`

- **Severidad base:** MEDIUM
- **Detección:** identificador que coincide con una palabra reservada del estándar SQL o del dialecto declarado: `order`, `user`, `group`, `table`, `select`, `key`, `desc`, `date`, `check`, `values`, `default`, `primary`, `range`, `rank`, `system`.
- **Condición formal:**
  ```
  IF identificador ∈ palabras_reservadas(dialecto_declarado)
  THEN severity = MEDIUM AND confidence = VERIFIED
  # v1.4, tras el vector B-06 del red team:
  IF NO se declaró dialecto
  THEN comprobar solo contra la lista de palabras reservadas del ESTÁNDAR ANSI
   AND confidence = UNVERIFIED
   AND redactar en condicional: "si el motor es <X>, <ident> es palabra reservada"
   AND añadir a Información faltante
  ```
- **Justificación:** un identificador que coincide con una palabra reservada obliga a entrecomillarlo (`` `order` ``, `"order"`, `[order]`) **en todas y cada una de las consultas que lo usen, para siempre**. Cualquier consulta que olvide las comillas falla con un error de sintaxis que no señala la causa, y la sintaxis de entrecomillado difiere entre motores, así que el SQL deja de ser portable. El caso más costoso es el diferido: una columna válida hoy puede convertirse en palabra reservada en una versión futura del motor —le ha ocurrido a `rank`, `system` y `groups`—, y entonces la actualización rompe la aplicación entera. La corrección de v1.4 evita el falso positivo inverso: afirmar que `status` es reservada sin saber el motor sería exactamente el tipo de afirmación no verificada que la skill prohíbe.
- **Falsos positivos:** identificadores reservados en un dialecto y libres en otro (`status` no es reservada en MySQL pero sí aparece en listas de otros motores) — por eso, sin dialecto declarado, el hallazgo es `UNVERIFIED`.
- **Corrección:**
  ```sql
  -- ANTES
  CREATE TABLE `order` (`key` INT, `date` DATE);
  -- DESPUÉS: nombres no reservados y descriptivos, sin necesidad de comillas
  CREATE TABLE pedido (
    pedido_id   BIGINT       NOT NULL,
    fecha_pedido DATE        NOT NULL,
    PRIMARY KEY (pedido_id)
  );
  ```
- **Requiere contexto:** Sí — el dialecto. Consulta: la lista de reservadas del motor (`SELECT * FROM information_schema.keywords;` en MySQL 8).

---

## CONV-005 — Alias ausente o ambiguo en consultas multi-tabla

- **Severidad base:** LOW
- **Detección:** consulta con ≥2 tablas donde una columna se referencia sin calificar (`SELECT nombre FROM a JOIN b …`), o alias asignados sin `AS` en la proyección, o el mismo alias reutilizado en niveles distintos.
- **Condición formal:**
  ```
  IF count(tablas) >= 2 AND existe columna sin calificar THEN severity = LOW
  IF la columna sin calificar existe en más de una de las tablas (verificable con schema_ddl)
  THEN severity = MEDIUM   # ambigüedad real, la consulta puede fallar o cambiar de significado
  ```
- **Justificación:** una columna sin calificar en una consulta multi-tabla resuelve contra la primera tabla que la contenga. Si más adelante se añade una columna con el mismo nombre a la otra tabla, la consulta **cambia de significado sin fallar** o pasa a dar un error de ambigüedad en producción. Calificar no es un adorno: fija la resolución del nombre y hace que la consulta sea inmune a cambios en el esquema de las otras tablas.
- **Falsos positivos:** consultas de una sola tabla → no aplica.
- **Corrección:**
  ```sql
  SELECT u.nombre AS nombre_usuario, p.total AS total_pedido
    FROM usuarios u
    JOIN pedidos  p ON p.usuario_id = u.id;
  ```
- **Requiere contexto:** Sí, para elevar a MEDIUM — las columnas de cada tabla.

---

## CONV-006 — Objeto no calificado por esquema en DDL

- **Severidad base:** LOW
- **Detección:** `CREATE`/`ALTER`/`DROP` sin prefijo de esquema (`CREATE TABLE usuarios` en vez de `CREATE TABLE tienda.usuarios`), en un script que no declara `USE`/`SET search_path`.
- **Condición formal:**
  ```
  IF DDL sin esquema calificado AND no existe USE / SET search_path en el script
  THEN severity = LOW
   AND si el script contiene DROP -> severity = MEDIUM  (riesgo de actuar sobre el esquema equivocado)
  ```
- **Justificación:** sin calificar, el objeto se crea en el esquema por defecto de la sesión, que depende de la conexión y no del script. El mismo archivo ejecutado por dos personas con configuraciones distintas produce resultados diferentes, y en el caso de un `DROP` puede destruir el objeto homónimo del esquema equivocado — un fallo que ocurre precisamente cuando se ejecuta un script de producción con una sesión apuntando a otro sitio.
- **Falsos positivos:** scripts que declaran `USE tienda;` o `SET search_path = tienda;` al inicio → no aplica, la ambigüedad está resuelta.
- **Corrección:**
  ```sql
  USE tienda;                                   -- o calificar cada objeto
  CREATE TABLE tienda.usuarios ( ... );
  ```
- **Requiere contexto:** No.

---

## CONV-007 — `CREATE TABLE` sin clave primaria `[REGLA PROPIA]`

- **Severidad base:** HIGH
- **Detección:** `CREATE TABLE` sin `PRIMARY KEY` a nivel de columna ni de tabla, y sin `UNIQUE NOT NULL` que haga sus veces.
- **Condición formal:**
  ```
  IF CREATE TABLE AND NOT existe PRIMARY KEY AND NOT existe UNIQUE NOT NULL
  THEN severity = HIGH
   AND nota = "sin identidad de fila no hay UPDATE/DELETE seguro ni replicación fiable"
  IF es CREATE TEMPORARY TABLE THEN severity = LOW  (vida limitada a la sesión)
  ```
- **Justificación:** sin clave primaria no existe forma de referirse a una fila concreta, y de ahí se derivan tres consecuencias en cadena. **(1)** Ningún `UPDATE`/`DELETE` puede acotarse a una fila: todo predicado es potencialmente múltiple, lo que hace que SEC-003 sea inevitable sobre esa tabla. **(2)** Se pueden insertar duplicados exactos que después es imposible distinguir ni eliminar selectivamente. **(3)** La replicación basada en filas de MySQL degrada a recorrido completo por cada fila modificada, porque necesita localizar la fila en la réplica sin clave — con impacto de varios órdenes de magnitud en el retraso. Es la única regla de convención que llega a HIGH, y por eso: no es estética, es la precondición de todas las operaciones seguras sobre la tabla.
- **Falsos positivos:** tablas temporales de trabajo (`CREATE TEMPORARY TABLE`), tablas de hechos puramente *append-only* en un almacén analítico con clave lógica documentada → baja a LOW si el `purpose` lo declara.
- **Corrección:**
  ```sql
  CREATE TABLE usuarios (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    email      VARCHAR(255) NOT NULL,
    creado_en  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_usuarios_email (email)
  );
  ```
- **Requiere contexto:** No.

---

## CONV-008 — Relación implícita sin clave foránea

- **Severidad base:** MEDIUM
- **Detección:** en `CREATE TABLE`, columna cuyo nombre sugiere referencia (`*_id`, `id_*`, `*_fk`, `*_codigo`) sin `FOREIGN KEY` ni `REFERENCES` declarados, existiendo en la entrada una tabla candidata con ese nombre.
- **Condición formal:**
  ```
  IF columna coincide con /(_id|_fk)$|^id_/ AND NOT existe FOREIGN KEY sobre ella
  THEN severity = MEDIUM
   AND confidence = UNVERIFIED   # la FK podría estar declarada fuera de la entrada
   AND redactar en condicional
  ```
- **Justificación:** sin la restricción, la integridad referencial queda delegada en la aplicación, y basta un script de mantenimiento, una carga masiva o un error de concurrencia para introducir filas huérfanas. El problema es que las huérfanas se descubren tarde —al intentar declarar la FK, que entonces falla— y para entonces hay que decidir qué hacer con datos que no debían existir. La FK además informa al optimizador sobre la cardinalidad de la relación, lo que mejora los planes de *join*.
- **Falsos positivos:** referencias entre esquemas o bases distintas donde la FK no es posible; particionado que impide FK en algunos motores; diseños analíticos donde se prescinde de FK deliberadamente por rendimiento de carga → se emite igualmente como MEDIUM `UNVERIFIED`, con la nota de que la decisión puede ser deliberada.
- **Corrección:**
  ```sql
  ALTER TABLE pedidos
    ADD CONSTRAINT fk_pedidos_usuario
    FOREIGN KEY (usuario_id) REFERENCES usuarios (id)
    ON DELETE RESTRICT;
  -- Comprobar antes que no hay huérfanos:
  SELECT p.id FROM pedidos p
    LEFT JOIN usuarios u ON u.id = p.usuario_id
   WHERE u.id IS NULL;
  ```
- **Requiere contexto:** Sí — si la FK ya existe. Consulta: `SELECT * FROM information_schema.table_constraints WHERE table_name = 'pedidos' AND constraint_type = 'FOREIGN KEY';`

---

# NULL — Lógica trivaluada

> Base común de esta familia: SQL no usa lógica booleana de dos valores sino **trivaluada**
> (`TRUE`, `FALSE`, `UNKNOWN`). Un `WHERE` solo devuelve la fila si el predicado evalúa a
> `TRUE`; `UNKNOWN` se comporta como `FALSE` **a efectos de filtrado, pero no a efectos de
> negación** — y esa asimetría es la fuente de todos los errores de esta familia.

## NULL-001 — Comparación de igualdad con `NULL`

- **Severidad base:** HIGH
- **Detección:** `= NULL`, `<> NULL`, `!= NULL`, `> NULL`, `IN (NULL)`, `NOT IN (NULL)`.
- **Condición formal:**
  ```
  IF existe comparación con el literal NULL usando un operador distinto de IS / IS NOT
  THEN severity = HIGH
   AND nota = "el predicado evalúa a UNKNOWN y NUNCA devuelve filas"
  IF ocurre en un UPDATE/DELETE
  THEN severity = HIGH   # el statement no hace nada; el bug es que se cree que sí lo hace
  ```
- **Justificación:** `NULL` significa "valor desconocido", así que `x = NULL` pregunta "¿es `x` igual a un valor desconocido?", cuya respuesta es necesariamente desconocida: el resultado es `UNKNOWN`, nunca `TRUE`. En consecuencia el filtro **no devuelve ninguna fila jamás**, con independencia de los datos. Es un bug silencioso de primer orden: no hay error de sintaxis, no hay error de ejecución, la consulta devuelve cero filas y todo el mundo concluye que "no hay datos que cumplan la condición". En un `UPDATE` el efecto es que el statement se ejecuta con éxito y no modifica nada, y el fallo se detecta días después.
- **Falsos positivos:** ninguno conocido. `= NULL` es siempre un error. (MySQL con `SET ANSI_NULLS OFF` en SQL Server antiguo lo trataba como `IS NULL`; ese modo está obsoleto y su uso es en sí mismo un hallazgo.)
- **Corrección:**
  ```sql
  -- ANTES
  SELECT id FROM usuarios WHERE fecha_baja = NULL;
  -- DESPUÉS
  SELECT id FROM usuarios WHERE fecha_baja IS NULL;
  -- Comparación segura entre dos columnas que pueden ser NULL:
  SELECT id FROM t WHERE a IS NOT DISTINCT FROM b;   -- PostgreSQL
  SELECT id FROM t WHERE a <=> b;                    -- MySQL
  ```
- **Requiere contexto:** No.

---

## NULL-002 — `NOT IN` sobre una subconsulta que puede devolver `NULL` `[REGLA PROPIA]`

- **Severidad base:** HIGH
- **Detección:** `NOT IN (SELECT col FROM …)` donde `col` no está declarada `NOT NULL` de forma demostrable en la entrada.
- **Condición formal:**
  ```
  IF existe NOT IN (subconsulta)
     AND la columna proyectada NO es demostrablemente NOT NULL
  THEN severity = HIGH
   AND confidence = UNVERIFIED si no se aportó schema_ddl
   AND nota = "si la subconsulta devuelve algún NULL, el resultado será el conjunto VACÍO"
   AND fix = NOT EXISTS
  ```
- **Justificación:** `x NOT IN (a, b, NULL)` se expande a `x <> a AND x <> b AND x <> NULL`. El último operando evalúa a `UNKNOWN`, y `TRUE AND UNKNOWN` es `UNKNOWN`, que no es `TRUE`: la fila no se devuelve. Basta **un solo `NULL`** en la subconsulta para que la consulta completa devuelva cero filas, sea cual sea el resto de los datos. Lo insidioso es que funciona correctamente mientras no haya `NULL`s —es decir, durante todo el desarrollo y las pruebas— y falla el día en que aparece el primero en producción, sin error alguno. `NOT EXISTS` no tiene este problema porque se evalúa por existencia de fila, no por comparación de valores.
- **Falsos positivos:** columna declarada `NOT NULL` en el `schema_ddl` aportado → no se emite. Sin esquema, el hallazgo se mantiene `UNVERIFIED`, porque la skill no puede saberlo.
- **Corrección:**
  ```sql
  -- ANTES (frágil)
  SELECT id FROM usuarios
   WHERE id NOT IN (SELECT usuario_id FROM pedidos);
  -- DESPUÉS (inmune a NULL)
  SELECT u.id FROM usuarios u
   WHERE NOT EXISTS (SELECT 1 FROM pedidos p WHERE p.usuario_id = u.id);
  -- Alternativa si se quiere conservar NOT IN:
  SELECT id FROM usuarios
   WHERE id NOT IN (SELECT usuario_id FROM pedidos WHERE usuario_id IS NOT NULL);
  ```
- **Requiere contexto:** Sí — nullabilidad de la columna. Consulta: `SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'pedidos';`

---

## NULL-003 — Negación sobre columna nullable

- **Severidad base:** MEDIUM
- **Detección:** predicados `<>`, `!=`, `NOT LIKE`, `NOT BETWEEN` sobre una columna que no es demostrablemente `NOT NULL`, sin `OR col IS NULL` acompañante.
- **Condición formal:**
  ```
  IF predicado de negación sobre columna potencialmente nullable
     AND NOT existe cláusula OR col IS NULL
  THEN severity = MEDIUM
   AND confidence = UNVERIFIED
   AND nota = "las filas con NULL en esa columna se excluyen silenciosamente"
  ```
- **Justificación:** intuitivamente `estado <> 'ACTIVO'` significa "todo lo que no está activo", pero las filas con `estado IS NULL` **no se devuelven**, porque `NULL <> 'ACTIVO'` es `UNKNOWN`. El conjunto resultante no es el complementario de `estado = 'ACTIVO'`: la unión de ambos no cubre la tabla. Esto rompe el razonamiento habitual de "una consulta y su negación suman el total" y produce informes cuyas cifras no cuadran sin que nada falle.
- **Falsos positivos:** columna declarada `NOT NULL` → no aplica; por eso el hallazgo es `UNVERIFIED` sin esquema.
- **Corrección:**
  ```sql
  -- ANTES
  SELECT id FROM usuarios WHERE estado <> 'ACTIVO';
  -- DESPUÉS: decidir explícitamente qué se hace con los NULL
  SELECT id FROM usuarios WHERE estado <> 'ACTIVO' OR estado IS NULL;
  -- Mejor aún: eliminar la ambigüedad en el modelo
  ALTER TABLE usuarios MODIFY estado VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE';
  ```
- **Requiere contexto:** Sí — nullabilidad.

---

## NULL-004 — Agregación afectada por `NULL` sin declararlo

- **Severidad base:** LOW
- **Detección:** `COUNT(columna)` (frente a `COUNT(*)`), `AVG(col)`, `SUM(col)` sobre columnas potencialmente nullables sin `COALESCE` ni filtro previo.
- **Condición formal:**
  ```
  IF COUNT(columna_nullable) THEN severity = LOW  (cuenta solo los no nulos)
  IF AVG(columna_nullable)   THEN severity = MEDIUM (el denominador excluye los NULL)
  IF la agregación alimenta un cálculo de negocio (importes) THEN severity = MEDIUM
  ```
- **Justificación:** las funciones de agregación **ignoran los `NULL`**, y en `AVG` eso cambia el denominador: la media de `(10, 20, NULL)` es 15, no 10. Si el `NULL` significaba "cero" —caso frecuente en importes— el resultado es incorrecto en un sentido que nadie audita, porque el número parece razonable. `COUNT(col)` frente a `COUNT(*)` es la misma trampa: dos cifras distintas que se usan indistintamente en informes.
- **Falsos positivos:** cuando ignorar los `NULL` es exactamente la intención (media de las valoraciones existentes) → INFO, si es evidente por el contexto de la consulta.
- **Corrección:**
  ```sql
  -- Decidir explícitamente el tratamiento del NULL
  SELECT AVG(COALESCE(valoracion, 0)) AS media_contando_sin_valorar,
         AVG(valoracion)              AS media_solo_valorados,
         COUNT(*)                     AS filas_totales,
         COUNT(valoracion)            AS filas_con_valoracion
    FROM resenas;
  ```
- **Requiere contexto:** Sí — el significado de negocio del `NULL` en esa columna.

---

## NULL-005 — Concatenación con posible `NULL`

- **Severidad base:** MEDIUM
- **Detección:** `CONCAT(...)` u operador `||` con al menos un operando potencialmente nullable, sin `COALESCE`.
- **Condición formal:**
  ```
  IF concatenación con operando potencialmente nullable AND NOT existe COALESCE
  THEN severity = MEDIUM
   AND confidence = UNVERIFIED
   AND documentar la divergencia entre motores
  ```
- **Justificación:** el comportamiento **difiere entre motores**, lo que convierte el mismo SQL en dos programas distintos: en PostgreSQL y Oracle con `||`, cualquier operando `NULL` anula la expresión completa y devuelve `NULL`; en MySQL, `CONCAT()` también devuelve `NULL`, pero `CONCAT_WS()` ignora los `NULL`; en SQL Server el resultado depende del ajuste `CONCAT_NULL_YIELDS_NULL`. Un nombre completo construido por concatenación desaparece por completo si falta el segundo apellido, y el error se manifiesta como campos vacíos en una interfaz, sin traza en los registros.
- **Falsos positivos:** operandos declarados `NOT NULL` → no aplica.
- **Corrección:**
  ```sql
  SELECT CONCAT_WS(' ', nombre, apellido1, COALESCE(apellido2, '')) AS nombre_completo
    FROM usuarios;
  ```
- **Requiere contexto:** Sí — nullabilidad y dialecto.
- **Divergencia motor:** PostgreSQL/Oracle (`||` → `NULL`), MySQL (`CONCAT` → `NULL`, `CONCAT_WS` → ignora), SQL Server (configurable).

---

## NULL-006 — Columna sin `NOT NULL` ni `DEFAULT` en `CREATE TABLE`

- **Severidad base:** MEDIUM
- **Detección:** en `CREATE TABLE`, columna sin `NOT NULL` y sin `DEFAULT`, cuyo nombre sugiere un dato obligatorio (`email`, `nombre`, `fecha_creacion`, `estado`, `precio`, `cantidad`, `*_id`).
- **Condición formal:**
  ```
  IF columna sin NOT NULL AND sin DEFAULT AND el nombre sugiere obligatoriedad
  THEN severity = MEDIUM
   AND confidence = UNVERIFIED   # la obligatoriedad es una regla de negocio, no se infiere
   AND redactar como pregunta: "¿es <col> opcional? Si no lo es, declarar NOT NULL"
  ```
- **Justificación:** una columna nullable permite dos estados que la aplicación casi nunca distingue: "no informado" y "informado como vacío". Cada consulta que la use deberá decidir qué hacer con el `NULL`, y basta que una lo olvide para que el resultado sea incorrecto (ver NULL-003 y NULL-004). Declarar `NOT NULL` traslada la comprobación del código —donde hay que repetirla en cada punto— al motor, donde se aplica una sola vez y sin excepciones. Nótese que la skill **no puede decidir** si una columna es obligatoria: eso es negocio. Por eso el hallazgo se emite como pregunta, no como afirmación.
- **Falsos positivos:** columnas genuinamente opcionales (`segundo_apellido`, `fecha_baja`, `observaciones`) → el hallazgo es una pregunta, no un error; se responde con el contexto de negocio.
- **Corrección:**
  ```sql
  CREATE TABLE usuarios (
    id        BIGINT       NOT NULL AUTO_INCREMENT,
    email     VARCHAR(255) NOT NULL,                 -- obligatorio
    telefono  VARCHAR(20)  NULL,                     -- opcional, declarado a propósito
    estado    VARCHAR(20)  NOT NULL DEFAULT 'ACTIVO',
    PRIMARY KEY (id)
  );
  ```
- **Requiere contexto:** Sí — reglas de negocio. **No se inventan.**

---

## NULL-007 — `NULL` usado como valor de negocio

- **Severidad base:** INFO
- **Detección:** `NULL` insertado o asignado explícitamente en columnas de estado o de clasificación; `COALESCE(col, 'DESCONOCIDO')` en la proyección, que revela que el `NULL` codifica una categoría.
- **Condición formal:**
  ```
  IF NULL se usa como categoría de negocio
  THEN severity = INFO
   AND nota = "NULL significa 'desconocido', no 'no aplica' ni 'ninguno'; considerar un valor explícito"
  ```
- **Justificación:** `NULL` tiene un único significado en el modelo relacional —valor desconocido— y usarlo para codificar "no aplica", "pendiente" o "ninguno" mezcla tres conceptos que después no se pueden distinguir. Además, esos valores quedan fuera de todos los índices en algunos motores, se excluyen de las agregaciones y obligan a tratamiento especial en cada consulta. Es INFO y no un nivel superior porque, sin conocer el modelo de negocio, la skill **no puede determinar** si el uso es incorrecto: solo puede señalar la ambigüedad.
- **Falsos positivos:** uso correcto de `NULL` como "aún desconocido" (`fecha_entrega` de un pedido no entregado) → es el uso canónico.
- **Corrección:**
  ```sql
  -- Codificar el estado de forma explícita y dejar NULL solo para lo desconocido
  ALTER TABLE pedidos MODIFY estado VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE';
  ```
- **Requiere contexto:** Sí — el modelo de negocio.

---

# TYPE — Elección de tipos de datos

## TYPE-001 — `VARCHAR` sobredimensionado

- **Severidad base:** LOW
- **Detección:** `VARCHAR(n)`/`NVARCHAR(n)` con `n > VARCHAR_OVERSIZE` (1000) para campos cuyo nombre indica dominio acotado (`email`, `telefono`, `codigo_postal`, `dni`, `estado`, `pais`); o uso sistemático de `VARCHAR(255)` para todo.
- **Condición formal:**
  ```
  IF VARCHAR(n) AND n > VARCHAR_OVERSIZE AND el nombre sugiere dominio acotado
  THEN severity = LOW
  IF la columna se usa en un índice AND n > 255 THEN severity = MEDIUM
  ```
- **Justificación:** el tamaño declarado no ocupa espacio si no se usa, pero sí tiene tres costes reales: **(1)** los motores reservan memoria por la longitud **declarada** al construir tablas temporales y al ordenar, de modo que un `VARCHAR(4000)` multiplica el consumo de una operación de `ORDER BY`; **(2)** existen límites duros de longitud de clave de índice (767/3072 bytes en InnoDB según formato), y un `VARCHAR` largo no cabe entero en el índice; **(3)** la declaración es documentación: `VARCHAR(4000)` para un código postal indica que nadie modeló el dominio, y sin restricción de longitud entran datos basura que después hay que limpiar.
- **Falsos positivos:** campos de texto libre genuinos (`observaciones`, `descripcion`) → no aplica; para esos, valorar `TEXT`.
- **Corrección:**
  ```sql
  email        VARCHAR(255) NOT NULL,   -- límite práctico de una dirección de correo
  codigo_postal CHAR(5)     NOT NULL,   -- longitud fija y conocida
  pais         CHAR(2)      NOT NULL,   -- ISO 3166-1 alfa-2
  ```
- **Requiere contexto:** Sí — el dominio real del dato.

---

## TYPE-002 — Importes monetarios en tipo de coma flotante `[REGLA PROPIA]`

- **Severidad base:** HIGH
- **Detección:** columna declarada `FLOAT`, `DOUBLE`, `REAL` o `DOUBLE PRECISION` cuyo nombre indica dinero: `precio`, `importe`, `total`, `saldo`, `monto`, `coste`, `iva`, `descuento`, `balance`, `amount`, `salary`.
- **Condición formal:**
  ```
  IF tipo ∈ (FLOAT, DOUBLE, REAL) AND el nombre sugiere valor monetario
  THEN severity = HIGH
   AND fix = DECIMAL(p, s) con escala explícita
   AND nota = "los errores de redondeo se acumulan y son irrecuperables"
  ```
- **Justificación:** `FLOAT` y `DOUBLE` usan representación binaria IEEE 754, en la que la mayoría de las fracciones decimales **no tienen representación exacta**: `0.1` se almacena como una aproximación, y `0.1 + 0.2` no es igual a `0.3`. El efecto sobre dinero es doble. Primero, cada operación introduce un error que se acumula, de modo que la suma de un millón de líneas de factura no coincide con el total y el descuadre crece con el volumen. Segundo, y peor, `WHERE total = 19.99` puede no devolver la fila que muestra `19.99` en pantalla, porque el valor almacenado es `19.989999999999998`: el dato existe y la consulta no lo encuentra. `DECIMAL` usa representación decimal exacta y es aritméticamente correcto para dinero. Este error es especialmente costoso porque solo se detecta en auditoría contable, cuando ya hay años de datos con desviaciones.
- **Falsos positivos:** magnitudes físicas donde la coma flotante es apropiada (`temperatura`, `latitud`, `peso_kg`, `porcentaje_ocupacion`) → no aplica. La distinción se hace por el nombre; si es ambiguo, se emite `UNVERIFIED` con la pregunta.
- **Corrección:**
  ```sql
  -- ANTES
  precio FLOAT,
  -- DESPUÉS: precisión y escala explícitas
  precio DECIMAL(12,2) NOT NULL,     -- hasta 10 dígitos enteros y 2 decimales
  -- Para tipos de cambio o precios unitarios con más decimales:
  precio_unitario DECIMAL(18,6) NOT NULL,
  ```
- **Requiere contexto:** No — la incompatibilidad entre coma flotante y dinero es una propiedad del tipo, no de los datos.

---

## TYPE-003 — Fechas u horas almacenadas como texto

- **Severidad base:** HIGH
- **Detección:** columna `VARCHAR`/`CHAR`/`TEXT` cuyo nombre indica temporalidad (`fecha`, `date`, `hora`, `time`, `creado_en`, `updated_at`, `timestamp`, `*_dt`); o comparación de una columna de texto con un literal de fecha.
- **Condición formal:**
  ```
  IF tipo textual AND el nombre indica fecha/hora
  THEN severity = HIGH
   AND nota = "comparación lexicográfica, sin validación y sin funciones de fecha"
  ```
- **Justificación:** una fecha en texto se compara **lexicográficamente**, no cronológicamente. Con formato `DD/MM/YYYY`, `'01/02/2026'` es menor que `'02/01/2025'` como cadena, así que cualquier `ORDER BY` o `BETWEEN` produce resultados incorrectos sin error alguno; solo el formato ISO `YYYY-MM-DD` ordena bien por casualidad. Además, el motor no valida el contenido —`'2026-02-31'` se acepta—, no se pueden usar funciones de fecha sin conversión (que además rompe el índice, ver PERF-005), y no hay forma de representar la zona horaria. Al almacenar en tipo nativo, todo eso lo resuelve el motor.
- **Falsos positivos:** columnas que almacenan una fecha parcial o imprecisa por requisito de dominio (`'1985'`, `'2020-03'`) → se mantiene el hallazgo en MEDIUM con la nota de que existe `DATE` parcial en algunos motores.
- **Corrección:**
  ```sql
  -- ANTES
  fecha_alta VARCHAR(10),
  -- DESPUÉS
  fecha_alta DATE NOT NULL,
  creado_en  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- Migración segura, validando antes:
  SELECT fecha_alta FROM usuarios WHERE STR_TO_DATE(fecha_alta, '%Y-%m-%d') IS NULL;
  ```
- **Requiere contexto:** No.

---

## TYPE-004 — Booleano codificado como texto sin restricción

- **Severidad base:** MEDIUM
- **Detección:** columna `CHAR(1)`/`VARCHAR(1)` con nombre de predicado (`activo`, `borrado`, `es_*`, `is_*`, `tiene_*`, `flag_*`) sin `CHECK` que acote los valores admitidos.
- **Condición formal:**
  ```
  IF columna de aspecto booleano con tipo textual AND NOT existe CHECK
  THEN severity = MEDIUM
  IF existe CHECK que acota los valores THEN severity = LOW
  ```
- **Justificación:** sin restricción, la columna admite `'S'`, `'N'`, `'s'`, `'n'`, `'Y'`, `'1'`, `' '` y cadena vacía, y con el tiempo aparecen todos porque distintas partes del sistema escriben con criterios distintos. A partir de ahí, cada consulta necesita saber qué convenciones existen (`WHERE activo IN ('S','s','Y','1')`) y basta olvidar una para perder filas silenciosamente. El tipo booleano nativo, o un `CHECK` explícito, hacen que el conjunto de valores sea una garantía del motor y no una convención que hay que recordar.
- **Falsos positivos:** columnas con tres estados reales (`'S'`, `'N'`, `NULL` = pendiente) → sigue necesitando `CHECK`; el hallazgo se mantiene.
- **Corrección:**
  ```sql
  -- Mejor: tipo nativo
  activo BOOLEAN NOT NULL DEFAULT TRUE,          -- PostgreSQL
  activo TINYINT(1) NOT NULL DEFAULT 1,          -- MySQL
  -- Si hay que conservar el texto por compatibilidad, acotarlo:
  activo CHAR(1) NOT NULL DEFAULT 'S',
  CONSTRAINT ck_usuarios_activo CHECK (activo IN ('S','N'))
  ```
- **Requiere contexto:** No.

---

## TYPE-005 — `CHAR` para contenido de longitud variable

- **Severidad base:** LOW
- **Detección:** `CHAR(n)` con `n > 10` sobre columnas de contenido variable (`nombre`, `direccion`, `email`, `descripcion`).
- **Condición formal:**
  ```
  IF CHAR(n) AND n > 10 AND el contenido es de longitud variable
  THEN severity = LOW
  ```
- **Justificación:** `CHAR` rellena con espacios hasta la longitud declarada, así que además de desperdiciar almacenamiento introduce un problema de comparación: según el motor y la *collation*, los espacios finales se ignoran en unas operaciones y no en otras, de modo que `'ana'` y `'ana   '` pueden ser iguales en un `WHERE` y distintos en un `GROUP BY` o en una clave única. `CHAR` solo es adecuado cuando la longitud es realmente fija (`CHAR(2)` para país ISO, `CHAR(5)` para código postal).
- **Falsos positivos:** columnas de longitud genuinamente fija → no aplica.
- **Corrección:** `nombre VARCHAR(100) NOT NULL`.
- **Requiere contexto:** No.

---

## TYPE-006 — Marca temporal sin zona horaria

- **Severidad base:** MEDIUM
- **Detección:** `DATETIME` (MySQL) o `TIMESTAMP WITHOUT TIME ZONE` (PostgreSQL) en columnas de evento (`creado_en`, `ocurrido_en`, `enviado_en`, `login_at`).
- **Condición formal:**
  ```
  IF columna de marca temporal de evento AND tipo sin zona horaria
  THEN severity = MEDIUM
   AND nota = "el instante no queda determinado; ambigüedad en cambios de horario"
  ```
- **Justificación:** un `DATETIME` guarda una lectura de reloj, no un instante: `2026-10-25 02:30:00` ocurre **dos veces** la noche del cambio de horario de verano, y en el cambio inverso no ocurre nunca. Un sistema con servidores en zonas distintas —o migrado a la nube— acaba con registros cuyo orden real es indeterminable, lo que rompe cualquier reconstrucción cronológica y cualquier auditoría. Almacenar con zona (o siempre en UTC, de forma documentada) elimina la ambigüedad.
- **Falsos positivos:** fechas civiles sin instante asociado (`fecha_nacimiento`, `fecha_factura`) → `DATE` es correcto y la regla no aplica.
- **Corrección:**
  ```sql
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),           -- PostgreSQL
  creado_en TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP, -- MySQL: se almacena en UTC
  ```
- **Requiere contexto:** Sí — la política de zonas horarias del sistema.

---

## TYPE-007 — Clave primaria textual o UUID sin justificación

- **Severidad base:** LOW
- **Detección:** `PRIMARY KEY` sobre `VARCHAR`/`CHAR(36)`/`UUID` almacenado como texto.
- **Condición formal:**
  ```
  IF PRIMARY KEY sobre tipo textual THEN severity = LOW AND confidence = UNVERIFIED
  IF además es UUID v4 en CHAR(36) en motor con índice agrupado (InnoDB, SQL Server)
  THEN severity = MEDIUM   # fragmentación del índice por inserción aleatoria
  ```
- **Justificación:** en motores con índice agrupado (InnoDB, SQL Server), la clave primaria determina el orden físico de las filas **y se copia en todos los índices secundarios**. Una clave de 36 bytes en lugar de 8 multiplica por más de cuatro el tamaño de cada entrada de índice secundario, reduciendo cuántas caben por página y aumentando las lecturas. Además, un UUID v4 es aleatorio, de modo que cada inserción cae en una página distinta y provoca divisiones de página y fragmentación, en lugar de la inserción secuencial al final que permite un entero autoincremental. UUID v7 (ordenable temporalmente) o almacenamiento binario de 16 bytes mitigan ambos efectos. La regla es LOW porque la decisión suele estar justificada por requisitos distribuidos, que la skill no conoce.
- **Falsos positivos:** claves naturales estables y cortas (`CHAR(2)` para país); sistemas distribuidos donde la generación en cliente es un requisito real → nota informativa.
- **Corrección:**
  ```sql
  -- Si se necesita UUID, almacenarlo en binario y usar una versión ordenable
  id BINARY(16) NOT NULL,        -- en lugar de CHAR(36)
  PRIMARY KEY (id)
  -- O clave sustituta numérica + UUID como columna única para el exterior
  id      BIGINT NOT NULL AUTO_INCREMENT,
  uuid_ext BINARY(16) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_uuid (uuid_ext)
  ```
- **Requiere contexto:** Sí — arquitectura del sistema.

---

## TYPE-008 — Rango de entero insuficiente

- **Severidad base:** LOW
- **Detección:** `INT`/`INTEGER` (máx. ≈2,1 × 10⁹ con signo) o `SMALLINT` en columnas de identificador autoincremental o de contador de alto volumen (`id`, `*_id`, `evento_id`, `log_id`, `transaccion_id`).
- **Condición formal:**
  ```
  IF PK autoincremental de tipo INT o menor
  THEN severity = LOW AND confidence = UNVERIFIED
   AND redactar en condicional: "si la tabla supera ~2.1e9 filas acumuladas, el contador se agota"
  IF el nombre sugiere tabla de eventos/logs THEN severity = MEDIUM
  ```
- **Justificación:** el agotamiento del contador no se manifiesta como degradación sino como **parada total**: los `INSERT` empiezan a fallar con error de clave duplicada y no hay solución rápida, porque migrar la columna a `BIGINT` requiere reescribir la tabla y todos los índices —y todas las claves foráneas que la referencian— con la tabla bloqueada. Lo relevante es que el contador consume valores por inserciones **intentadas**, no por filas vivas: una tabla de eventos que borra periódicamente sigue agotándolo. La regla es `UNVERIFIED` porque el volumen futuro no es observable desde el SQL.
- **Falsos positivos:** catálogos pequeños y estables (`paises`, `estados`) donde `INT` sobra de largo → INFO.
- **Corrección:**
  ```sql
  id BIGINT NOT NULL AUTO_INCREMENT,   -- ~9.2e18, suficiente en la práctica
  ```
- **Requiere contexto:** Sí — volumen esperado. Consulta: `SELECT MAX(id), AUTO_INCREMENT FROM …;`

---

## TYPE-009 — Tipos incompatibles entre columnas relacionadas

- **Severidad base:** MEDIUM
- **Detección:** columna `*_id` cuyo tipo difiere del de la clave primaria a la que referencia, cuando ambas están en la entrada: `usuarios.id BIGINT` frente a `pedidos.usuario_id INT`; diferencias de signo (`UNSIGNED` vs con signo); diferencias de *collation* entre columnas unidas por `JOIN`.
- **Condición formal:**
  ```
  IF tipo(columna_fk) != tipo(columna_pk_referenciada)  [ambas visibles en la entrada]
  THEN severity = MEDIUM
   AND nota = "impide declarar la FOREIGN KEY y fuerza conversión implícita en el JOIN"
   AND referencia cruzada -> PERF-012
  ```
- **Justificación:** la mayoría de los motores **rechazan** una `FOREIGN KEY` entre columnas de tipos distintos, así que el error impide declarar la integridad referencial y arrastra a CONV-008. Aunque se prescinda de la FK, cada `JOIN` entre ambas columnas obliga a una conversión implícita que puede impedir el uso del índice (PERF-012), y el problema se agrava con *collations* distintas en columnas de texto, donde la comparación deja de ser indexable. Un `INT` frente a `BIGINT` añade además el riesgo de que la referencia deje de poder representar los identificadores de la tabla padre cuando esta supere el rango.
- **Falsos positivos:** ninguno cuando ambos tipos son visibles en la entrada; si solo se ve uno, no se emite (no se infiere el otro).
- **Corrección:**
  ```sql
  ALTER TABLE pedidos MODIFY usuario_id BIGINT NOT NULL;
  ALTER TABLE pedidos
    ADD CONSTRAINT fk_pedidos_usuario FOREIGN KEY (usuario_id) REFERENCES usuarios (id);
  ```
- **Requiere contexto:** No, si ambas definiciones están en la entrada. En caso contrario no se emite.
