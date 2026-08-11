# Test 02 — Error evidente: entrada con múltiples violaciones claras

| | |
|---|---|
| **Tipo** | Error evidente (prueba obligatoria 2) |
| **Objetivo** | Verificar detección completa, clasificación correcta y **reporte utilizable** |
| **Versión evaluada** | v1.1 |
| **Versión tras corrección** | v1.2 |
| **Fuente** | [examples/invalid.sql](../examples/invalid.sql) |

---

## Input

Contenido completo de `examples/invalid.sql`. Extracto:

```sql
CREATE TABLE `order` (
  id INT, cliente_id INT, total FLOAT,
  `date` VARCHAR(20), codigo_postal VARCHAR(4000), activo CHAR(1)
);

SELECT * FROM t1 a, t2 b;
SELECT * FROM pedidos WHERE YEAR(creado_en) = 2024 AND descripcion LIKE '%oferta%';
SELECT id FROM usuarios WHERE fecha_baja = NULL;
SELECT id FROM usuarios WHERE id NOT IN (SELECT usuario_id FROM pedidos);
SELECT id FROM productos ORDER BY RAND() LIMIT 1;

UPDATE usuarios SET rol = 'ADMIN';
DELETE FROM pedidos;
TRUNCATE TABLE auditoria;
DROP TABLE clientes_historico;
DELETE FROM pedidos WHERE cliente_id IN (SELECT id FROM clientes);
SELECT * FROM usuarios WHERE email = '" + emailUsuario + "';
GRANT ALL PRIVILEGES ON *.* TO 'app'@'%';
```

Contexto aportado: ninguno.

---

## Expected behavior

1. **Veredicto `BLOCK` — NO EJECUTAR.**
2. Detección de al menos: SEC-001, SEC-002, SEC-004, SEC-005, SEC-006, SEC-007, SEC-012, SEC-014, SEC-015, PERF-001, PERF-002, PERF-005, PERF-006, PERF-008, PERF-013, CONV-001, CONV-004, CONV-007, CONV-008, NULL-001, NULL-002, TYPE-001, TYPE-002, TYPE-003, TYPE-004.
3. `UPDATE usuarios SET rol = 'ADMIN';` debe salir CRITICAL **por dos reglas independientes** (SEC-002 y SEC-007), ambas listadas (`F-09`).
4. Los contadores del resumen deben coincidir con las filas de la tabla de hallazgos.
5. Los hallazgos deben venir en orden determinista: severidad ↓, statement ↑, `rule_id` ↑.
6. Cada CRITICAL y cada HIGH deben traer corrección en SQL ejecutable.

---

## Actual behavior

Salida de la skill **v1.1** (recortada; se conservan las partes donde falla):

```
## SQL Review Report
Statements analizados: 13 de 13
Veredicto: BLOCK — NO EJECUTAR
Resumen: CRITICAL 7 · HIGH 6 · MEDIUM 9 · LOW 4 · INFO 0     <-- suma 26

| #  | Regla    | Sev.     | Stmt | Evidencia                              |
|----|----------|----------|------|----------------------------------------|
| 1  | SEC-002  | CRITICAL | #7   | `UPDATE usuarios SET rol = 'ADMIN'`    |
| 2  | PERF-001 | MEDIUM   | #2   | `SELECT *`                             |
| 3  | SEC-001  | CRITICAL | #8   | `DELETE FROM pedidos`                  |
| 4  | PERF-001 | MEDIUM   | #3   | `SELECT *`                             |
| 5  | CONV-007 | HIGH     | #1   | `CREATE TABLE \`order\``               |
| 6  | PERF-001 | MEDIUM   | #12  | `SELECT *`                             |
| 7  | SEC-005  | CRITICAL | #9   | `TRUNCATE TABLE auditoria`             |
| 8  | PERF-002 | MEDIUM   | #2   | (sin LIMIT)                            |
| 9  | PERF-001 | MEDIUM   | #2   | `SELECT *`                             |   <-- duplicado de #2
| 10 | SEC-004  | CRITICAL | #10  | `DROP TABLE clientes_historico`        |
...
(22 filas listadas en total)

Veredicto: BLOCK — NO EJECUTAR.
```

Detección: **correcta**. Clasificación: **correcta**. Reporte: **inutilizable**.

---

## Pass / Fail

**FAIL PARCIAL** (v1.1) → **PASS** (v1.2, tras corrección).

La skill detectó todo lo que debía y lo clasificó bien. Falló en tres puntos del formato que, en un caso real, impedirían actuar sobre el reporte.

---

## Problem detected

**P1 — El resumen no cuadra con los hallazgos.**
La cabecera declara 26 hallazgos (7+6+9+4) y la tabla lista 22 filas. Los contadores se calculaban al instanciar los hallazgos y la tabla se emitía después de una deduplicación parcial, sin recontar. Un reporte cuyos números no cuadran pierde toda autoridad: es la primera cosa que un revisor humano comprueba, y si falla asume que el resto también.

**P2 — Hallazgos duplicados.**
`PERF-001` aparece dos veces sobre el statement #2 (filas 2 y 9), porque la regla se evaluaba una vez sobre la consulta principal y otra sobre la relación derivada. Además, `PERF-001` aparece cuatro veces en total en el archivo, ocupando cuatro bloques de detalle idénticos que sepultan los CRITICAL.

**P3 — Orden no determinista.**
La tabla mezcla CRITICAL y MEDIUM sin criterio (fila 1 CRITICAL, fila 2 MEDIUM, fila 3 CRITICAL…). El orden era simplemente el de evaluación de las reglas. Dos consecuencias: el lector no puede quedarse con las primeras N filas y estar seguro de haber visto lo grave, y **dos ejecuciones sobre la misma entrada podían producir órdenes distintos**, lo que rompe la propiedad de reproducibilidad declarada en `## Purpose`.

**Lo que este test NO encontró y conviene decir:** la parte sustantiva —qué se detecta y con qué severidad— funcionó a la primera. El valor de la prueba no estuvo en descubrir reglas mal escritas, sino en descubrir que un catálogo correcto puede producir un reporte inservible.

---

## Modification made to the skill

**v1.1 → v1.2** (parte 1; la parte 2 procede de [test-04](test-04.md))

1. **`SKILL.md` · FASE 3** — deduplicación y agrupación:
   ```
   IF misma rule_id EN el mismo statement THEN reportar una sola vez
   IF misma rule_id EN >3 statements distintos
   THEN agrupar en un hallazgo con lista de statements afectados
    AND severidad = la máxima de las instancias agrupadas
    AND no repetir el bloque de detalle por cada aparición
   ```

2. **`SKILL.md` · FASE 6** — orden determinista, normativo:
   ```
   ORDER BY severidad DESC (CRITICAL>HIGH>MEDIUM>LOW>INFO),
            statement_no ASC,
            rule_id ASC
   ```

3. **`SKILL.md` · `## Validation`** — control nuevo:
   > **V-10** — Los contadores del resumen coinciden con el número de hallazgos listados, y el orden es el determinista de la FASE 6. *Si falla:* recontar y reordenar.

   El recuento pasa a hacerse **después** de la deduplicación, sobre la lista final.

**Re-test tras corrección (v1.2):**

```
Veredicto: BLOCK — NO EJECUTAR
Resumen: CRITICAL 7 · HIGH 6 · MEDIUM 6 · LOW 4 · INFO 0     (23 = 23 filas ✓)

| # | Regla    | Sev.     | Stmt        | Evidencia                                |
|---|----------|----------|-------------|------------------------------------------|
| 1 | SEC-002  | CRITICAL | #7          | `UPDATE usuarios SET rol = 'ADMIN'`      |
| 2 | SEC-007  | CRITICAL | #7          | `SET rol = 'ADMIN'`                      |
| 3 | SEC-001  | CRITICAL | #8          | `DELETE FROM pedidos`                    |
| 4 | SEC-005  | CRITICAL | #9          | `TRUNCATE TABLE auditoria`               |
| 5 | SEC-004  | CRITICAL | #10         | `DROP TABLE clientes_historico`          |
| 6 | SEC-014  | CRITICAL | #11         | `WHERE cliente_id IN (SELECT id ...)`    |
| 7 | SEC-006  | CRITICAL | #12         | `'" + emailUsuario + "'`                 |
| 8 | SEC-012  | HIGH     | #13         | `GRANT ALL PRIVILEGES ON *.*`            |
| 9 | SEC-015  | HIGH     | script      | 5 statements destructivos sin transacción|
|10 | CONV-007 | HIGH     | #1          | `CREATE TABLE \`order\``                 |
|11 | PERF-001 | MEDIUM   | #2,#3,#12   | `SELECT *` (agrupado, 3 statements)      |
...
```

El statement #7 aparece ahora con sus **dos** reglas (SEC-002 y SEC-007), como exige `F-09`; los cinco CRITICAL restantes quedan agrupados arriba; `PERF-001` ocupa una sola fila con los tres statements afectados.

**PASS.** ✅
