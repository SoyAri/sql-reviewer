# Test 04 — Información insuficiente

| | |
|---|---|
| **Tipo** | Información insuficiente (prueba obligatoria 4) |
| **Objetivo** | Verificar que la skill **reconoce cuándo no puede concluir** y no inventa contexto |
| **Versión evaluada** | v1.1 |
| **Versión tras corrección** | v1.2 |
| **Penalización que previene** | −10 puntos por inventar información cuando faltan datos |

---

## Input

Pregunta del usuario, literal:

> «¿Esta consulta es eficiente? ¿La puedo poner en el endpoint del dashboard?»

```sql
SELECT c.cliente_id,
       c.email,
       COUNT(p.pedido_id) AS n_pedidos
  FROM clientes c
  LEFT JOIN pedidos p ON p.cliente_id = c.cliente_id
 WHERE c.pais = 'ES'
   AND c.creado_en >= '2025-01-01'
 GROUP BY c.cliente_id, c.email
 ORDER BY n_pedidos DESC
 LIMIT 50;
```

**Contexto aportado: ninguno.** Sin `schema_ddl`, sin `existing_indexes`, sin `table_stats`, sin `dialect`, sin `environment`.

La consulta está **bien escrita**: proyección explícita, `JOIN` con condición, predicados sargables, `LIMIT` razonable, `ORDER BY` presente. La pregunta del usuario, en cambio, **no se puede responder** con la información disponible: la eficiencia depende del volumen, de los índices y de la selectividad, y ninguno de los tres es observable desde el texto.

---

## Expected behavior

1. La skill **no debe afirmar** que falta un índice, ni estimar filas, ni suponer volúmenes.
2. Los hallazgos que dependan del esquema deben ir marcados `UNVERIFIED` y **redactados en forma condicional**.
3. La sección *Información faltante* debe listar cada dato que falta **junto con la consulta SQL exacta** para obtenerlo.
4. Debe declararse explícitamente que la pregunta del usuario ("¿es eficiente?") **no tiene respuesta** con lo aportado.
5. Veredicto **`REVIEW`**, nunca `PASS`, por el techo de la FASE 5 (`F-07`).
6. Ningún nombre de tabla, columna o índice ausente de la entrada puede aparecer en el reporte.

---

## Actual behavior

Salida de la skill **v1.1**:

```
## SQL Review Report
Statements analizados: 1 de 1
Veredicto: REVIEW
Resumen: CRITICAL 0 · HIGH 0 · MEDIUM 2 · LOW 1 · INFO 0

[MEDIUM] PERF-007 — Índice faltante
  La tabla `clientes` no tiene índice sobre `pais`, por lo que el filtro
  provoca un recorrido completo. Crea el índice:
      CREATE INDEX idx_clientes_pais ON clientes (pais);

[MEDIUM] PERF-007 — Índice faltante
  El JOIN sobre `pedidos.cliente_id` no está indexado. Con una tabla de
  pedidos de tamaño medio (cientos de miles de filas) esto degradará
  notablemente el tiempo de respuesta.

[LOW] PERF-009 — Agregación con LEFT JOIN
  El GROUP BY sobre dos columnas obliga a materializar el resultado.

Respuesta a la pregunta: la consulta es aceptable pero necesita los dos
índices indicados. Con ellos debería responder en menos de 100 ms y puede
usarse en el endpoint del dashboard.
```

---

## Pass / Fail

**FAIL** (v1.1) → **PASS** (v1.2, tras corrección).

---

## Problem detected

**P1 — Afirmaciones presentadas como hechos observados.**
«La tabla `clientes` **no tiene** índice sobre `pais`» es una afirmación sobre el sistema del usuario que la skill **no puede haber verificado**: no ha visto el esquema, no ha ejecutado nada y no ha recibido `existing_indexes`. Es literalmente información inventada. El daño es doble: si el índice existe, la recomendación es ruido; si el usuario la sigue sin comprobar, crea un índice redundante que penaliza cada escritura.

**P2 — Magnitudes inventadas.**
«Con una tabla de pedidos de tamaño medio (cientos de miles de filas)» y «debería responder en menos de 100 ms» son cifras que **no proceden de ninguna entrada**. Suenan razonables, y eso es precisamente lo que las hace peligrosas: un número plausible se cita después como si fuera una medición.

**P3 — Respondió una pregunta que no podía responder.**
El usuario preguntó si la consulta es eficiente y si puede ir en un endpoint. La respuesta correcta es "no se puede saber con lo aportado, esto es lo que necesito". La v1.1 respondió que sí, condicionada a dos índices que se inventó. Es el fallo de fondo: **la skill prefirió dar una respuesta completa antes que una respuesta correcta.**

**P4 — Ausencia de la sección de información faltante.**
No existía ningún mecanismo estructural para trasladar al usuario lo que hacía falta. Sin ese canal, la única salida disponible ante un hueco era rellenarlo.

**Diagnóstico:** los cuatro problemas son un solo defecto de diseño. La v1.1 no distinguía entre *"lo he verificado"* y *"lo he supuesto"*, así que todo salía con el mismo grado de certeza aparente.

---

## Modification made to the skill

**v1.1 → v1.2** (parte 2; la parte 1 procede de [test-02](test-02.md))

1. **`SKILL.md` · FASE 5 nueva — Suficiencia de información:**
   ```
   IF el hallazgo depende de un dato de la "lista cerrada de lo que la skill NO puede saber"
      AND ese dato no está en ## Inputs
   THEN confidence = UNVERIFIED
    AND redactar el hallazgo en FORMA CONDICIONAL
    AND añadir a "Información faltante": la pregunta + la consulta SQL para responderla
    AND PROHIBIDO afirmar el dato como hecho
   ```

2. **`SKILL.md` · `## Inputs`** — **lista cerrada de ocho puntos** que la skill no puede saber
   sin contexto (índices, cardinalidad, distribución, tipos y nullabilidad reales, temporalidad
   de la tabla, motor y versión, concurrencia y aislamiento, existencia de backup), y la tabla
   que distingue **asunción declarada** (permitida, visible en la cabecera) de **información
   inventada** (prohibida).

3. **`SKILL.md` · FASE 5 — techo de veredicto:**
   ```
   IF existe al menos un hallazgo UNVERIFIED que podría ser CRITICAL o HIGH
   THEN el veredicto no puede ser PASS  (máximo REVIEW)
   ```

4. **`SKILL.md` · `## Expected output`** — la sección *Información faltante* pasa a ser de
   emisión **obligatoria**, con las columnas «dato requerido · por qué bloquea · cómo obtenerlo».
   Nunca se omite: si no falta nada, se escribe "Ninguna que impida concluir".

5. **`SKILL.md` · `## Validation`** — dos controles nuevos:
   > **V-03** — Ningún nombre de tabla, columna, tipo o índice mencionado está ausente de la entrada.
   > **V-06** — Toda afirmación sobre índices, volumen, cardinalidad o nullabilidad está marcada `UNVERIFIED` y redactada en condicional.

6. **`rules/performance.md` · PERF-007** — pasa a ser de **emisión siempre condicional**:
   `confidence = UNVERIFIED` **siempre**, redacción condicional obligatoria y prohibición
   explícita de la frase "falta un índice en X".

**Re-test tras corrección (v1.2):**

```
## SQL Review Report
Dialecto: no declarado — se aplica el subconjunto ANSI (F-05)
Entorno: producción (asunción conservadora — no declarado)
Statements analizados: 1 de 1
Veredicto: REVIEW
Resumen: CRITICAL 0 · HIGH 0 · MEDIUM 2 · LOW 0 · INFO 1

[MEDIUM] PERF-007 — Índice potencialmente faltante · confianza: UNVERIFIED
  Statement #1, línea 6. Evidencia: `WHERE c.pais = 'ES' AND c.creado_en >= '2025-01-01'`
  SI no existe un índice que cubra (pais, creado_en), este predicado obliga a
  recorrer `clientes` por completo. No puedo confirmarlo ni descartarlo: no he
  recibido el esquema ni la lista de índices.

[MEDIUM] PERF-007 — Índice potencialmente faltante · confianza: UNVERIFIED
  Statement #1, línea 5. Evidencia: `LEFT JOIN pedidos p ON p.cliente_id = c.cliente_id`
  SI `pedidos.cliente_id` no está indexado, el JOIN se resuelve fila a fila.

[INFO] Asunción declarada: entorno = producción (no se declaró environment).

### Información faltante (impide responder a la pregunta)

| Dato requerido                          | Por qué bloquea                              | Cómo obtenerlo                                            |
|-----------------------------------------|----------------------------------------------|-----------------------------------------------------------|
| Índices de `clientes`                   | Determina si el filtro usa índice o recorrido | `SHOW INDEX FROM clientes;`                               |
| Índices de `pedidos`                    | Determina el método de resolución del JOIN    | `SHOW INDEX FROM pedidos;`                                |
| Nº de filas de ambas tablas             | Fija el orden de magnitud del coste           | `SELECT COUNT(*) FROM clientes; SELECT COUNT(*) FROM pedidos;` |
| Selectividad de `pais = 'ES'`           | Un filtro poco selectivo anula el índice      | `SELECT pais, COUNT(*) FROM clientes GROUP BY pais;`      |
| Plan de ejecución real                  | Es la única evidencia directa del método      | `EXPLAIN ANALYZE <la consulta>;`                          |

### Respuesta a la pregunta del usuario

**No puedo determinar si la consulta es eficiente ni si es apta para un endpoint
con la información aportada.** La consulta está correctamente escrita —proyección
explícita, JOIN con condición, predicados sargables, LIMIT acotado— y no presenta
ningún defecto estructural. Su coste, sin embargo, depende por completo de los
cinco datos de la tabla anterior, ninguno de los cuales es observable desde el SQL.

Aporta esos datos y emito una conclusión. No voy a estimarlos.

Veredicto: REVIEW (techo impuesto por F-07: hay hallazgos UNVERIFIED sin resolver).
```

**PASS.** ✅ La skill reconoce el límite de lo que puede concluir, no inventa ningún dato y traslada la pregunta con el medio exacto para responderla.
