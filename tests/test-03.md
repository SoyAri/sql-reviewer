# Test 03 — Edge case: parece correcto en la superficie

| | |
|---|---|
| **Tipo** | Edge case (prueba obligatoria 3) |
| **Objetivo** | Verificar que la skill razona sobre el **impacto** del statement, no sobre la presencia de cláusulas |
| **Versión evaluada** | v1.2 |
| **Versión tras corrección** | v1.3 |
| **Fuente** | [examples/edge-cases.sql](../examples/edge-cases.sql), casos E-01 a E-06, E-14, E-15 |

---

## Input

Todos los statements tienen `WHERE`. Ninguno tiene error de sintaxis. Los tres primeros son **literalmente** los que el enunciado propone para la fase de red team.

```sql
-- E-01
DELETE FROM TA_USERS WHERE 1 = 1;

-- E-02
SELECT * FROM TA_USERS LIMIT 1000000000;

-- E-03
UPDATE TA_USERS SET FCROLE = 'ADMIN' WHERE FCEMAIL LIKE '%';

-- E-04
DELETE FROM sesiones WHERE 2 > 1;
DELETE FROM sesiones WHERE token IS NULL OR token IS NOT NULL;

-- E-05
DELETE FROM pedidos WHERE pedido_id = 42 OR 1 = 1;

-- E-06
SELECT cliente_id, email FROM clientes LIMIT 999999;

-- E-14
UPDATE cuentas SET saldo = 0 WHERE saldo > -1;

-- E-15
DELETE FROM pedidos WHERE cliente_id IN (SELECT cliente_id FROM clientes);
```

Contexto aportado: ninguno.

---

## Expected behavior

| Caso | Clasificación esperada | Hallazgo esperado |
|---|---|---|
| E-01 | `TAUTOLOGICAL` · `WHOLE_TABLE` | SEC-003 **CRITICAL**, NO EJECUTAR |
| E-02 | `UNBOUNDED` (el `LIMIT` no acota) | PERF-003 **HIGH** + PERF-001 MEDIUM + PERF-004 MEDIUM |
| E-03 | `TAUTOLOGICAL` + columna de privilegio | SEC-003 **CRITICAL** + SEC-007 **CRITICAL** |
| E-04 | `TAUTOLOGICAL` (sin contener la cadena `1=1`) | SEC-003 **CRITICAL** ×2 |
| E-05 | `TAUTOLOGICAL` (el `OR` toma el máximo) | SEC-003 **CRITICAL** |
| E-06 | `UNBOUNDED` (999 999 > 10 000) | PERF-003 **HIGH** |
| E-14 | `TAUTOLOGICAL` si la columna es `UNSIGNED`; si no, `UNKNOWN` | SEC-003 CRITICAL `VERIFIED` **o** HIGH `UNVERIFIED` + pregunta |
| E-15 | `NON_RESTRICTIVE` | SEC-014 → E1 → **CRITICAL** |

Veredicto global: **`BLOCK` — NO EJECUTAR**.

---

## Actual behavior

Salida de la skill **v1.2**:

```
## SQL Review Report
Statements analizados: 9 de 9
Veredicto: REVIEW
Resumen: CRITICAL 0 · HIGH 1 · MEDIUM 4 · LOW 0 · INFO 3

| # | Regla    | Sev.   | Stmt | Evidencia                          |
|---|----------|--------|------|------------------------------------|
| 1 | SEC-007  | HIGH   | #3   | `SET FCROLE = 'ADMIN'`             |
| 2 | PERF-001 | MEDIUM | #2   | `SELECT *`                         |
| 3 | PERF-004 | MEDIUM | #2   | `LIMIT 1000000000` (sin ORDER BY)  |
| 4 | PERF-004 | MEDIUM | #7   | `LIMIT 999999` (sin ORDER BY)      |
| 5 | PERF-014 | MEDIUM | #8   | `UPDATE cuentas SET saldo = 0`     |
| 6 | SEC-001  | INFO   | #1   | WHERE presente — revisar alcance   |
| 7 | SEC-001  | INFO   | #4   | WHERE presente — revisar alcance   |
| 8 | SEC-001  | INFO   | #9   | WHERE presente — revisar alcance   |

Veredicto: REVIEW — revisar los MEDIUM antes del release.
```

Statements que la v1.2 dejó pasar **sin ningún hallazgo**: E-04 (segundo), E-05, y el `DELETE` de E-01 solo recibió un INFO.

---

## Pass / Fail

**FAIL** (v1.2) → **PASS** (v1.3, tras corrección).

Este es el fallo más grave de toda la serie de pruebas: la skill dio veredicto `REVIEW` a un lote en el que **cinco statements borran o modifican tablas completas**. Un equipo que confiara en ese reporte habría ejecutado el script.

---

## Problem detected

**P1 — La comprobación del `WHERE` era sintáctica, no semántica.**
La v1.2 implementaba literalmente `IF DELETE AND WHERE is absent THEN CRITICAL`. Con `WHERE` presente, la regla no se disparaba y el statement caía en una rama informativa ("WHERE presente — revisar alcance"). El resultado es que **escribir siete caracteres, `WHERE 1=1`, degradaba un CRITICAL a un INFO**. Cualquier control basado en presencia de cláusula tiene esta propiedad, y es exactamente lo que el enunciado del red team pide explotar.

**P2 — El `LIMIT` se contaba como mitigación, sin mirar su valor.**
`LIMIT 1000000000` satisfacía la comprobación de PERF-002 ("¿tiene LIMIT?"), así que el hallazgo de volumen no se emitía; solo saltó PERF-004 por la ausencia de `ORDER BY`, que es un problema menor y distinto. La skill estaba tratando como acotada una consulta que devuelve la tabla entera.

**P3 — El `OR` no se analizaba en su conjunto (E-05).**
`WHERE pedido_id = 42 OR 1 = 1` no produjo hallazgo alguno: el analizador encontraba un predicado de igualdad por clave primaria y concluía que el statement era selectivo, sin evaluar el segundo operando. Es el caso más peligroso de los tres porque el statement **parece revisado**: tiene un filtro concreto y verosímil.

**P4 — Sin vocabulario para hablar del impacto.**
Detrás de P1, P2 y P3 hay una carencia común: la v1.2 no tenía ninguna representación de *cuántas filas toca un statement*. Sin ese concepto, la severidad solo podía derivarse de la forma sintáctica, y la forma sintáctica es trivial de falsificar.

---

## Modification made to the skill

**v1.2 → v1.3** (parte 1; la parte 2 procede de [test-05](test-05.md))

1. **`SKILL.md` · FASE 2.3 — `effective_predicate`.** Todo predicado se clasifica en
   `ABSENT | TAUTOLOGICAL | NON_RESTRICTIVE | RESTRICTIVE_UNKNOWN | RESTRICTIVE`,
   con lista cerrada de patrones tautológicos (`1=1`, `2>1`, `TRUE`, `'a'='a'`, `col=col`,
   `col IS NULL OR col IS NOT NULL`, `LIKE '%'`, `LIKE '%%'`, rango que cubre el dominio).
   Reglas de composición:
   ```
   AND(p1..pn) -> clase = min(clase(pi))     # el más restrictivo manda
   OR (p1..pn) -> clase = max(clase(pi))     # el más permisivo manda
   IF cualquier operando de un OR es TAUTOLOGICAL THEN predicado = TAUTOLOGICAL
   ```
   La regla del `OR` es la que resuelve E-05.

2. **`SKILL.md` · FASE 2.4 — `blast_radius`.**
   `SINGLE_ROW | BOUNDED | UNKNOWN | UNBOUNDED | WHOLE_TABLE`, derivado del predicado y no
   de la presencia de cláusulas. Incluye la regla que resuelve E-02 y E-06:
   ```
   IF existe LIMIT AND LIMIT.valor > LIMIT_MAX_ACCEPTABLE
   THEN blast_radius = UNBOUNDED
    AND NO tratar la presencia de LIMIT como mitigación
   ```

3. **`rules/security.md` · SEC-003 nueva** — *Predicado presente pero no restrictivo en DML destructivo*, CRITICAL, con la tabla completa de patrones tautológicos y el escalado `E1` como **piso**, no como promedio.

4. **`rules/performance.md` · PERF-003 nueva** — *`LIMIT` presente pero no acotante*, HIGH, con `LIMIT_MAX_ACCEPTABLE = 10000` justificado en `## Constants`.

5. **`SKILL.md` · `## Validation`** — control nuevo:
   > **V-05** — Todo statement DML/DDL destructivo tiene `effective_predicate` y `blast_radius` asignados. *Si falla:* volver a la FASE 2.

**Re-test tras corrección (v1.3):**

```
Veredicto: BLOCK — NO EJECUTAR
Resumen: CRITICAL 6 · HIGH 3 · MEDIUM 2 · LOW 0 · INFO 1

| # | Regla    | Sev.     | Stmt | Evidencia                              | Confianza  |
|---|----------|----------|------|----------------------------------------|------------|
| 1 | SEC-003  | CRITICAL | #1   | `WHERE 1 = 1`                          | VERIFIED   |
| 2 | SEC-003  | CRITICAL | #3   | `WHERE FCEMAIL LIKE '%'`               | VERIFIED   |
| 3 | SEC-007  | CRITICAL | #3   | `SET FCROLE = 'ADMIN'`                 | VERIFIED   |
| 4 | SEC-003  | CRITICAL | #4   | `WHERE 2 > 1`                          | VERIFIED   |
| 5 | SEC-003  | CRITICAL | #5   | `WHERE token IS NULL OR token IS NOT NULL` | VERIFIED |
| 6 | SEC-003  | CRITICAL | #6   | `WHERE pedido_id = 42 OR 1 = 1`        | VERIFIED   |
| 7 | SEC-014  | CRITICAL | #9   | `WHERE cliente_id IN (SELECT cliente_id ...)` | VERIFIED |
| 8 | PERF-003 | HIGH     | #2   | `LIMIT 1000000000`                     | VERIFIED   |
| 9 | PERF-003 | HIGH     | #7   | `LIMIT 999999`                         | VERIFIED   |
|10 | SEC-003  | HIGH     | #8   | `WHERE saldo > -1`                     | UNVERIFIED |
|11 | PERF-001 | MEDIUM   | #2   | `SELECT *`                             | VERIFIED   |
|12 | PERF-004 | MEDIUM   | #2,#7| `LIMIT` sin `ORDER BY` (agrupado)      | VERIFIED   |

Información faltante:
| Dato requerido                       | Por qué bloquea                          | Cómo obtenerlo                          |
| ¿`cuentas.saldo` es UNSIGNED?        | Determina si `saldo > -1` es tautológico | `SHOW COLUMNS FROM cuentas LIKE 'saldo';`|

Veredicto: BLOCK — NO EJECUTAR. Motivo: 7 hallazgos CRITICAL.
```

Nótese E-14 (`WHERE saldo > -1`): la skill **no afirma** que sea tautológico, porque eso depende de un dato que no tiene. Lo clasifica como HIGH `UNVERIFIED` y traslada la pregunta con la consulta exacta para responderla. Es el comportamiento que exige la FASE 5.

**PASS.** ✅ Los ocho casos, incluidos los tres literales del enunciado, quedan detectados.
