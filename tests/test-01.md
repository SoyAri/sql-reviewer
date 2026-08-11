# Test 01 — Happy path: SQL correcto

| | |
|---|---|
| **Tipo** | Happy path (prueba obligatoria 1) |
| **Objetivo** | Verificar que la skill **no genera problemas artificiales** sobre SQL correcto |
| **Versión evaluada** | v1.0 |
| **Versión tras corrección** | v1.1 |
| **Fuente** | [examples/valid.sql](../examples/valid.sql) |

---

## Input

Contenido completo de `examples/valid.sql`. Extracto de los fragmentos relevantes para el fallo encontrado:

```sql
CREATE TABLE tienda.pedidos (
  pedido_id  BIGINT        NOT NULL AUTO_INCREMENT,
  cliente_id BIGINT        NOT NULL,
  total      DECIMAL(12,2) NOT NULL,
  estado     VARCHAR(20)   NOT NULL DEFAULT 'PENDIENTE',
  creado_en  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (pedido_id),
  CONSTRAINT fk_pedidos_cliente FOREIGN KEY (cliente_id) REFERENCES tienda.clientes (cliente_id)
) ENGINE = InnoDB;

CREATE INDEX idx_pedidos_estado_creado ON tienda.pedidos (estado, creado_en);

SELECT p.pedido_id, p.total, p.estado, c.email
  FROM tienda.pedidos  p
  JOIN tienda.clientes c ON c.cliente_id = p.cliente_id
 WHERE p.estado    = 'PENDIENTE'
   AND p.creado_en >= '2026-01-01'
 ORDER BY p.creado_en DESC, p.pedido_id DESC
 LIMIT 100;

SELECT COUNT(*) FROM tienda.pedidos
 WHERE estado = 'CANCELADO' AND creado_en < '2025-01-01';

SELECT cliente_id, email, telefono
  FROM tienda.clientes
 WHERE cliente_id > ?
   AND telefono IS NULL
 ORDER BY cliente_id
 LIMIT 500;
```

Contexto aportado: ninguno (sin `dialect`, `schema_ddl` ni `existing_indexes`). El esquema completo está **dentro del propio script**, que es lo relevante para esta prueba.

---

## Expected behavior

1. **Veredicto `PASS`.**
2. Cero hallazgos de severidad `LOW` o superior.
3. Se admiten hallazgos `INFO` (por ejemplo, la asunción de entorno declarada en la cabecera).
4. La sección *Información faltante* aparece, aunque sea con "Ninguna que impida concluir".
5. Ningún hallazgo `PERF-007` sobre columnas cuyo índice se crea **en el mismo script**.
6. La verificación previa `SELECT COUNT(*) … WHERE …` no debe penalizarse: es exactamente el paso que las correcciones de SEC-001 y SEC-003 exigen.

---

## Actual behavior

Salida de la skill **v1.0**:

```
## SQL Review Report
Dialecto: MySQL (detectado — no declarado por el usuario)
Entorno: producción (asunción conservadora — no declarado)
Statements analizados: 16 de 16
Veredicto: REVIEW
Resumen: CRITICAL 0 · HIGH 0 · MEDIUM 3 · LOW 1 · INFO 0

| # | Regla    | Sev.   | Stmt | Evidencia                        |
|---|----------|--------|------|----------------------------------|
| 1 | PERF-007 | MEDIUM | #6   | `WHERE p.estado = 'PENDIENTE'`   |
| 2 | PERF-007 | MEDIUM | #6   | `AND p.creado_en >= '2026-01-01'`|
| 3 | PERF-007 | MEDIUM | #15  | `AND telefono IS NULL`           |
| 4 | PERF-015 | LOW    | #11  | `SELECT COUNT(*)`                |

[MEDIUM] PERF-007 — Índice potencialmente faltante
  Si no existe índice sobre `estado`, este predicado provoca recorrido completo.
[MEDIUM] PERF-007 — Índice potencialmente faltante
  Si no existe índice sobre `creado_en`, este predicado provoca recorrido completo.
[MEDIUM] PERF-007 — Índice potencialmente faltante
  Si no existe índice sobre `telefono`, este predicado provoca recorrido completo.
[LOW] PERF-015 — Agregación sobre tabla completa sin filtro

Veredicto: REVIEW — corregir los MEDIUM antes del release.
```

---

## Pass / Fail

**FAIL** (v1.0) → **PASS** (v1.1, tras corrección).

Motivo del fallo: el veredicto fue `REVIEW` en lugar de `PASS`, con 4 hallazgos, **los cuatro falsos positivos**.

---

## Problem detected

Tres defectos distintos, todos del mismo tipo: **ruido que destruye la credibilidad del revisor**.

**P1 — PERF-007 ignoraba la evidencia presente en la propia entrada.**
El script crea `idx_pedidos_estado_creado ON (estado, creado_en)` cuatro líneas antes de la consulta que usa exactamente esas dos columnas. La regla emitía el hallazgo de todos modos porque solo comprobaba "esta columna no es PK". El resultado es peor que un falso positivo cualquiera: la skill contradice información que tiene delante, lo que es indistinguible de no haber leído la entrada.

**P2 — PERF-007 se emitía sobre filtros residuales de una conjunción.**
En `WHERE cliente_id > ? AND telefono IS NULL`, el método de acceso lo fija `cliente_id` (clave primaria). Un índice sobre `telefono` no cambiaría el plan. Recomendarlo es técnicamente incorrecto, no solo ruidoso: llevaría a crear un índice inútil que penaliza cada escritura (ver PERF-016).

**P3 — PERF-015 penalizaba la verificación previa.**
La corrección que la propia skill propone para SEC-001 y SEC-003 empieza por `SELECT COUNT(*) FROM t WHERE <predicado>;`. La v1.0 marcaba ese `COUNT(*)` como hallazgo, de modo que **la skill penalizaba su propia recomendación**. Es una contradicción interna, no una diferencia de criterio.

**Por qué esto importa más de lo que parece:** la utilidad de un revisor automático depende por completo de que sus hallazgos se lean. Un revisor que emite tres MEDIUM falsos en un archivo correcto entrena al equipo a ignorarlo, y el día que emite un CRITICAL verdadero nadie lo mira. El *happy path* no es la prueba fácil: es la que protege el valor de todas las demás.

---

## Modification made to the skill

**v1.0 → v1.1**

1. **`rules/performance.md` · PERF-007** — añadidas dos cláusulas de supresión explícitas:
   ```
   S1. IF el CREATE INDEX correspondiente está en el mismo script
          OR el predicado usa la PK/UNIQUE declarada en el mismo script
       THEN NO emitir el hallazgo
   S2. IF el predicado es una conjunción (AND) y al menos un operando usa una
          columna indexada, PK o UNIQUE demostrable en la entrada
       THEN NO emitir PERF-007 sobre los operandos restantes de esa conjunción
   ```

2. **`rules/performance.md` · PERF-015** — la condición pasa de "sin `WHERE` restrictivo" (ambigua) a una condición sobre la clase del predicado:
   ```
   IF agregación AND effective_predicate IN (ABSENT, TAUTOLOGICAL, NON_RESTRICTIVE)
   THEN severity = LOW
   ```

3. **Todas las reglas de `rules/`** — el campo **`Falsos positivos`** pasa a ser obligatorio en el formato de regla. Una regla sin falsos positivos documentados no puede entrar en el catálogo: obliga a delimitar su alcance en el momento de escribirla, no en el momento de sufrirla.

**Re-test tras corrección (v1.1):**

```
Veredicto: PASS
Resumen: CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 0 · INFO 1
[INFO] Asunción declarada: entorno = producción (no se declaró environment).
Información faltante: ninguna que impida concluir.
```

**PASS.** ✅
