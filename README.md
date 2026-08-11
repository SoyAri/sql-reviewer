# sql-reviewer

Skill reutilizable que actúa como **revisor técnico de base de datos**: recibe SQL, lo analiza
contra un catálogo cerrado de 56 reglas deterministas y emite un reporte con hallazgos
clasificados en `CRITICAL` / `HIGH` / `MEDIUM` / `LOW` / `INFO`, con evidencia literal,
corrección en SQL ejecutable y veredicto de ejecución.

> Este repositorio **es** el paquete `sql-reviewer-skill/` del enunciado. Todo el contenido
> está en la raíz; no hay carpeta anidada.

**Versión actual:** v1.4.0 · **Estado:** 5/5 pruebas en PASS · fase de red team completada

---

## Índice

| Archivo | Contenido |
|---|---|
| **[SKILL.md](SKILL.md)** | Contrato de la skill: propósito, activación, entradas, pipeline de 7 fases, severidades, formato de salida, autovalidación y manejo de errores |
| [rules/security.md](rules/security.md) | `SEC-001` … `SEC-016` — destrucción de datos, inyección, privilegios, ofuscación, integridad |
| [rules/performance.md](rules/performance.md) | `PERF-001` … `PERF-016` — volumen, índices, sargabilidad, planes, bloqueos |
| [rules/conventions.md](rules/conventions.md) | `CONV-001…008`, `NULL-001…007`, `TYPE-001…009` — nombres, lógica trivaluada, tipos |
| [examples/valid.sql](examples/valid.sql) | SQL correcto. Resultado esperado: `PASS`, 0 hallazgos |
| [examples/invalid.sql](examples/invalid.sql) | Violaciones evidentes y múltiples. Resultado esperado: `BLOCK` |
| [examples/edge-cases.sql](examples/edge-cases.sql) | 15 casos que superan una comprobación superficial y siguen siendo peligrosos |
| [tests/](tests/) | Las 5 pruebas obligatorias, ejecutadas y documentadas |
| **[RED-TEAM.md](RED-TEAM.md)** | Fase de red team bidireccional: 12 vectores lanzados, 7 recibidos |

---

## Qué hace y qué no hace

| La skill SÍ hace | La skill NO hace |
|---|---|
| Detectar violaciones del catálogo `rules/` | Ejecutar SQL o conectarse a una base de datos |
| Clasificar cada hallazgo por severidad determinista | Generar SQL nuevo desde cero |
| Estimar el radio de impacto (`blast_radius`) de un statement | Adivinar el esquema, el volumen o los índices existentes |
| Proponer SQL corregido y ejecutable | Decidir si el cambio es correcto para el negocio |
| Declarar explícitamente lo que no puede verificar | Aprobar la ejecución en producción |

Los diez casos en los que **no debe activarse** están enumerados en
[`SKILL.md` § When NOT to activate](SKILL.md#when-not-to-activate), cada uno con la respuesta
exacta que debe dar.

---

## Cómo funciona

Pipeline de 7 fases. El orden es normativo: ninguna fase se salta y ninguna se reordena.

```
ENTRADA
  │
  ├─ FASE 0  Gate de activación ─────────► NO ACTIVAR (respuesta N-xx) ─► FIN
  ├─ FASE 1  Normalización y parseo ─────► PARSE_ERROR parcial (F-03)
  ├─ FASE 2  Clasificación por statement
  ├─ FASE 3  Evaluación del catálogo
  ├─ FASE 4  Severidad y escalado
  ├─ FASE 5  Suficiencia de información
  ├─ FASE 6  Emisión del reporte
  └─ FASE 7  Autovalidación (10 controles) ─► corregir │ ANALYSIS INCOMPLETE
  │
SALIDA
```

### Los tres conceptos que sostienen el análisis

**1. `effective_predicate`** — un `WHERE` no vale por estar, vale por filtrar. Todo predicado se
clasifica en `ABSENT | TAUTOLOGICAL | NON_RESTRICTIVE | RESTRICTIVE_UNKNOWN | RESTRICTIVE`,
con reglas de composición (`AND` toma el mínimo, `OR` toma el máximo).

**2. `blast_radius`** — cuántas filas toca el statement:
`SINGLE_ROW | BOUNDED | UNKNOWN | UNBOUNDED | WHOLE_TABLE`. Se deriva del predicado, no de la
presencia de cláusulas. Es lo que hace que `LIMIT 1000000000` se clasifique `UNBOUNDED`.

**3. `confidence`** — `VERIFIED` o `UNVERIFIED`. Todo lo que dependa de datos no observables
(índices, volumen, nullabilidad real, dialecto no declarado) se emite en **forma condicional**
y con la consulta SQL exacta para resolverlo. Nunca se afirma como hecho.

### Severidad calculada, no elegida

| `blast_radius` \ Reversibilidad | `IRREVERSIBLE` | `BACKUP` | `SESSION` |
|---|---|---|---|
| `WHOLE_TABLE` / esquema | **CRITICAL** | **HIGH** | **MEDIUM** |
| `UNBOUNDED` / `UNKNOWN` | **HIGH** | **MEDIUM** | **LOW** |
| `BOUNDED` / `SINGLE_ROW` | **MEDIUM** | **LOW** | **INFO** |

Más cinco reglas de escalado (`E1`…`E5`) y una única de de-escalado (`D1`), acotada por cuatro
condiciones para que no sea evadible. Detalle en [`SKILL.md` § Procedure](SKILL.md#procedure).

---

## Cobertura de los requisitos del enunciado

Las 11 detecciones mínimas exigidas, con las reglas que las implementan:

| # | Requisito | Reglas |
|---|---|---|
| 1 | Uso de `SELECT *` | `PERF-001` |
| 2 | `UPDATE`/`DELETE` sin condición `WHERE` **segura** | `SEC-001`, `SEC-002`, **`SEC-003`** |
| 3 | Operaciones potencialmente destructivas | `SEC-004`, `SEC-005`, `SEC-011`, `SEC-014` |
| 4 | Concatenaciones que faciliten SQL Injection | `SEC-006`, `SEC-009` |
| 5 | Nombres poco descriptivos / convenciones deficientes | `CONV-001` … `CONV-006` |
| 6 | Ausencia de `LIMIT` en consultas masivas | `PERF-002`, **`PERF-003`**, `PERF-004` |
| 7 | Uso incorrecto de `NULL` | `NULL-001` … `NULL-007` |
| 8 | Problemas en la elección de tipos de datos | `TYPE-001` … `TYPE-009` |
| 9 | Índices potencialmente faltantes | `PERF-007` (siempre `UNVERIFIED`) |
| 10 | Problemas razonables de rendimiento | `PERF-005`, `PERF-006`, `PERF-008` … `PERF-016` |
| 11 | **Violaciones adicionales definidas por el equipo** | ver abajo |

### Violaciones definidas por el equipo `[REGLA PROPIA]`

Doce reglas más allá del mínimo exigido. Las cinco marcadas con ★ nacieron de un fallo concreto
detectado en una prueba o en el red team:

| Regla | Qué añade |
|---|---|
| ★ **`SEC-003`** | Predicado presente pero no restrictivo. La regla central: neutraliza `WHERE 1=1`, `LIKE '%'`, `WHERE TRUE`, tautologías dentro de un `OR` |
| **`SEC-007`** | Escalado de privilegios: `SET rol = 'ADMIN'`, `GRANT ALL`, `WITH GRANT OPTION` |
| ★ **`SEC-010`** | Ofuscación sintáctica: `DEL/**/ETE`, comentarios ejecutables `/*! */`, `CHAR()`, hexadecimal |
| ★ **`SEC-013`** | Instrucción embebida dirigida al revisor. Defensa frente a inyección de instrucciones |
| **`SEC-015`** | Script con varios statements destructivos sin transacción, o transacción sin cerrar |
| ★ **`SEC-016`** | Desactivación de restricciones de integridad sin reactivación |
| ★ **`PERF-003`** | `LIMIT` presente pero no acotante (`> 10 000`) |
| **`PERF-012`** | Conversión implícita de tipo: rompe el índice y **cambia el conjunto devuelto** |
| **`CONV-004`** | Palabra reservada usada como identificador |
| **`CONV-007`** | `CREATE TABLE` sin clave primaria |
| **`NULL-002`** | `NOT IN` sobre subconsulta nullable → conjunto vacío |
| **`TYPE-002`** | Importes monetarios en coma flotante: error de redondeo acumulado y filas que no se encuentran |

---

## Pruebas

Las cinco pruebas obligatorias, todas ejecutadas. Cada una encontró un fallo **real** y produjo
una corrección versionada.

| Prueba | Tipo | Resultado | Fallo detectado | Corrección |
|---|---|---|---|---|
| [test-01](tests/test-01.md) | Happy path | FAIL → **PASS** | 4 falsos positivos sobre SQL correcto (`PERF-007` ×3, `PERF-015`) | Supresiones `S1`/`S2` de `PERF-007`; campo *Falsos positivos* obligatorio → **v1.1** |
| [test-02](tests/test-02.md) | Error evidente | FAIL parcial → **PASS** | Resumen descuadrado, hallazgos duplicados, orden no determinista | Deduplicación, orden normativo, control `V-10` → **v1.2** |
| [test-03](tests/test-03.md) | Edge case | FAIL → **PASS** | `WHERE 1=1` degradaba un CRITICAL a INFO; `LIMIT` gigante contaba como mitigación | `effective_predicate`, `blast_radius`, `SEC-003`, `PERF-003` → **v1.3** |
| [test-04](tests/test-04.md) | Info insuficiente | FAIL → **PASS** | Afirmaba índices y volúmenes inexistentes; respondió una pregunta que no podía responder | `confidence`, forma condicional, *Información faltante*, `V-03`/`V-06` → **v1.2** |
| [test-05](tests/test-05.md) | Adversarial | FAIL → **PASS** | Obedeció una instrucción embebida en un comentario y la presión del usuario | Fase de normalización, `SEC-010`, `SEC-013`, `V-08`, `F-10`/`F-11` → **v1.3** |

### Protocolo de ejecución

Las pruebas son de **especificación**: el revisor —un modelo siguiendo `SKILL.md`— recibe el
contenido de `## Input` sin contexto adicional y su salida se transcribe literalmente en
`## Actual behavior`. Para reproducir una prueba:

1. Cargar `SKILL.md` y `rules/` en una sesión nueva, sin más contexto.
2. Pegar exactamente el contenido de la sección `## Input` de la prueba.
3. Comparar la salida con `## Expected behavior`.

El criterio de fallo es objetivo: veredicto incorrecto, hallazgo esperado ausente, hallazgo no
esperado presente, o incumplimiento de cualquier control de `## Validation`.

---

## Fase de red team

Intercambio con el equipo de **Armando Valerio** (`RED-TEAM.md`, sesión del 2026-08-11).
Bidireccional: se documentan tanto los fallos encontrados en su skill como los que ellos
encontraron en la nuestra.

| Dirección | Vectores | Resistidos | Parciales | Rotos | Índice |
|---|---|---|---|---|---|
| Nosotros → su skill v1.0 | 12 | 7 | 3 | 2 | 8,5/12 (71 %) |
| Su equipo → nuestra skill v1.3 | 7 | 4 | 3 | 0 | 5,5/7 (79 %) |

Ningún vector rompió nuestra skill, pero **tres revelaron severidades infravaloradas** y
produjeron la **v1.4**: `SEC-014` reclasificado a `NON_RESTRICTIVE`, agrupación de hallazgos
repetidos, escalado `E5` y `CONV-004` dependiente del dialecto. Dos de ellos señalaban
incumplimientos de **nuestras propias reglas**, que es el tipo de fallo más difícil de ver
desde dentro.

Sus dos fallos y nuestros tres parciales son de naturaleza distinta: los suyos vienen de
trabajar sobre el texto crudo con listas de patrones; los nuestros, de infravalorar severidades
en casos donde la detección sí funcionaba.

`RED-TEAM.md` cierra con los **cuatro vectores aún no mitigados**, declarados abiertamente.

---

## Por qué esto no es un prompt largo

La penalización más cara del enunciado (−20) es que la skill sea «únicamente un prompt largo
disfrazado». Cinco propiedades que un prompt no tiene:

| Propiedad | Dónde |
|---|---|
| **Pipeline con estados tipados** — cada fase produce estructuras de dominio cerrado (`effective_predicate` tiene exactamente 5 valores) | `SKILL.md` FASE 0–7 |
| **Catálogo cerrado con identificadores** — 56 reglas; todo hallazgo debe citar una existente y la skill no puede inventar reglas durante el análisis | `rules/`, control `V-01` |
| **Severidad calculada, no elegida** — matriz `f(reversibilidad, blast_radius)` + escalados booleanos. Ningún punto dice "usa tu criterio" | `SKILL.md` § 4.2–4.4 |
| **Autovalidación con criterio de fallo** — 10 controles con acción correctiva y salida `ANALYSIS INCOMPLETE` | `SKILL.md` § Validation |
| **Versionado trazable a defectos** — v1.0 → v1.4, cada versión atada al test o vector que la provocó | `SKILL.md` § Version history |

La prueba operativa: la misma entrada produce el mismo conjunto de hallazgos, las mismas
severidades y el mismo orden. La reproducibilidad está declarada como propiedad exigida y el
orden de los hallazgos es normativo.

---

## Uso

### Como skill de Claude Code

`SKILL.md` lleva frontmatter YAML válido, así que el repositorio es instalable tal cual:

```bash
# Proyecto concreto
mkdir -p .claude/skills/sql-reviewer
cp -r SKILL.md rules/ .claude/skills/sql-reviewer/

# O para todos los proyectos
mkdir -p ~/.claude/skills/sql-reviewer
cp -r SKILL.md rules/ ~/.claude/skills/sql-reviewer/
```

Después basta con pedir una revisión:

```
Revisa este SQL:
DELETE FROM TA_USERS WHERE 1 = 1;
```

### Como especificación para cualquier otro sistema

`SKILL.md` es autocontenido: cargar su contenido más el de `rules/` como instrucciones de
sistema es suficiente. No depende de ninguna característica propia de un producto concreto.

---

## Correspondencia con las fases del enunciado

| Fase | Artefacto |
|---|---|
| Diseño — responsabilidad, entradas, salidas y límites | `SKILL.md` §§ Purpose, When to activate, When NOT to activate, Inputs |
| Construcción — SKILL.md y reglas | `SKILL.md` §§ Procedure, Rules, Severity levels, Expected output, Validation, Failure handling + `rules/` |
| Casos — ejemplos válidos, inválidos y límite | `examples/valid.sql`, `examples/invalid.sql`, `examples/edge-cases.sql` |
| Testing — mínimo 5 pruebas creadas y ejecutadas | `tests/test-01.md` … `tests/test-05.md` |
| Red Team — intentar romper la skill de otro equipo | `RED-TEAM.md` parte A (12 vectores) |
| Corrección — documentar y corregir los fallos | `RED-TEAM.md` parte B + `SKILL.md` § Version history (v1.4) |
| Defensa — demostración y preguntas | La justificación técnica de cada regla vive en el campo *Justificación* de `rules/`, y la de cada umbral en `SKILL.md` § Constants |

---

## Limitaciones conocidas

Se declaran porque una skill que afirma resistir todo no es creíble:

1. **SQL construido en tiempo de ejecución** a partir de variables no es analizable de forma
   estática. Se declara `SEC-009` + `NO VERIFICABLE` y se prohíbe el veredicto `PASS` (`F-11`).
   Es un límite del método, no un defecto corregible.
2. **La distribución real de los datos es invisible.** `WHERE pais = 'ES'` puede ser muy
   selectivo o afectar al 95 % de la tabla. Sin `table_stats` se emite `RESTRICTIVE_UNKNOWN` y
   se traslada la pregunta.
3. **`SENSITIVE_COLUMN_PATTERN` es una heurística por nombre.** Una columna `nivel_acceso` no
   coincide. Solo escala hallazgos existentes (`E2`), nunca los crea, de modo que su fallo
   degrada de forma segura.
4. **Las pruebas son manuales.** Están documentadas y son reproducibles, pero no hay suite
   automática de regresión.
5. **Cobertura de dialectos parcial.** Las divergencias documentadas cubren MySQL, PostgreSQL,
   SQL Server y Oracle en las reglas donde importa; no es exhaustivo.

---

## Historial de versiones

| Versión | Origen | Cambio |
|---|---|---|
| **1.0** | Diseño inicial | Pipeline de 5 fases, catálogo base, severidades, formato de salida. Comprobación del `WHERE` por **presencia** |
| **1.1** | `test-01` | Supresiones `S1`/`S2` de `PERF-007`; precisión de `PERF-015`; campo *Falsos positivos* obligatorio en todas las reglas |
| **1.2** | `test-02`, `test-04` | Deduplicación y orden determinista; control `V-10`; `confidence` obligatoria, forma condicional y sección *Información faltante*; controles `V-03` y `V-06` |
| **1.3** | `test-03`, `test-05` | **`effective_predicate` y `blast_radius`**; fase de normalización anti-ofuscación; reglas `SEC-003`, `SEC-010`, `SEC-013`, `SEC-016`, `PERF-003`; controles `V-05` y `V-08`; `F-10`/`F-11` |
| **1.4** | Red team (B-05 … B-07) | `SEC-014` → `NON_RESTRICTIVE`; agrupación de hallazgos repetidos; escalado `E5`; `CONV-004` dependiente del dialecto |
