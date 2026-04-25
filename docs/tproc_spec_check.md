# HammerDB TPROC-C / TPROC-H specification check (cross-database code review)

This note captures a source-level review of HammerDB TPROC-C and TPROC-H implementations for:
- Oracle
- SQL Server
- Db2
- MySQL
- MariaDB
- PostgreSQL

## Executive summary

- **Generally, the implementations are good**: all reviewed engines implement the canonical TPROC-C transaction set (`neword`, `delivery`, `payment`, `ostat`, `slev`) and include expected Payment bad-credit handling logic.
- **Good credit vs bad credit is not omitted**:
  - Load/build paths assign both `GC` and `BC` customer credit types.
  - Payment logic branches specifically on `BC`, updating `c_data` for bad-credit customers and doing balance-only update otherwise.
- **Common cross-engine caveat**: New-Order stock updates are broadly implemented as `s_quantity` updates only (despite stock tables carrying `s_ytd`, `s_order_cnt`, `s_remote_cnt`). This is the main strict-spec gap observed.

---

## 1) TPROC-C stored procedure coverage (all reviewed DBs)

All six reviewed engines include the five TPROC-C transactions in their TPROC-C implementations:
- `neword`
- `delivery`
- `payment`
- `ostat`
- `slev`

(See each `*oltp.tcl` file for the CREATE PROCEDURE blocks.)

## 2) Good credit / bad credit (`GC` / `BC`) comment resolution

### Finding
The comment that HammerDB omits good/bad credit is **not supported** by code.

### Evidence pattern seen across engines
1. **Customer load/build assigns both values**
   - Typical pattern: random assignment of `c_credit` to `"GC"` or `"BC"` during customer data generation.
2. **Payment explicitly tests bad credit**
   - Typical pattern: `IF p_c_credit = 'BC'` (or equivalent `CASE WHEN c_credit <> 'BC'`) then prepend/maintain `c_data` logic for BC customers.

So, both customer classes are present and handled.

## 3) Cross-engine caveat: stock counters in New-Order

### Finding
Across the reviewed engines, New-Order stock maintenance is commonly implemented with `s_quantity` updates only, while stock schema includes:
- `s_ytd`
- `s_order_cnt`
- `s_remote_cnt`

### Why this matters
For strict TPC-C semantic alignment, New-Order stock updates are usually expected to maintain those counters in addition to quantity.

---

## 4) Per-engine quick notes

### Oracle (`src/oracle/oraoltp.tcl`)
- Has `GC`/`BC` customer generation and `IF p_c_credit = 'BC'` branch in Payment.
- New-Order stock update observed as quantity update.

### SQL Server (`src/mssqlserver/mssqlsoltp.tcl`)
- Has `GC`/`BC` customer generation and Payment branch logic via `CASE WHEN c_credit <> 'BC'`.
- Stock schema includes counters (`s_ytd`, `s_order_cnt`, `s_remote_cnt`).

### Db2 (`src/db2/db2oltp.tcl`)
- Has `GC`/`BC` customer generation and `IF p_c_credit = 'BC'` in Payment.
- New-Order stock update uses quantity-change expression in `UPDATE STOCK ... SET s_quantity = ...`.

### MySQL (`src/mysql/mysqloltp.tcl`)
- Has `GC`/`BC` customer generation and `IF p_c_credit = 'BC'` in Payment.
- Stored-proc and non-stored New-Order paths both show quantity-only stock updates.

### MariaDB (`src/mariadb/mariaoltp.tcl`)
- Has `GC`/`BC` customer generation and `IF p_c_credit = 'BC'` in Payment.
- Stored-proc and non-stored New-Order paths show quantity-only stock updates.

### PostgreSQL (`src/postgresql/pgoltp.tcl`)
- Has `GC`/`BC` customer generation and `IF p_c_credit = 'BC'` in Payment.
- New-Order stock update observed as quantity update.

---

## 5) TPROC-H scope note

TPROC-H in HammerDB is implemented as driver/query/refresh logic (and not as a required set of DB-resident stored procedures in the same way as TPROC-C). For MySQL-family paths, refresh functions match RF1/RF2 style orchestration and there is a separate non-standard “Cloud Analytic TPCH” workload variant.

---

## 6) Recommendation

If you want strict TPROC-C semantic alignment across all engines, prioritize adding stock-counter maintenance in New-Order:
- `s_ytd = s_ytd + ol_quantity`
- `s_order_cnt = s_order_cnt + 1`
- `s_remote_cnt = s_remote_cnt + 1` for remote supplier warehouse lines.

Given the current codebase, the single biggest cross-engine semantic delta is this stock-counter behavior—not omission of good/bad credit handling.

---

## 7) Example: New-Order stock-counter maintenance

Below is a concrete pattern showing how to extend the existing quantity update so it also maintains stock counters.

### Generic SQL pattern

```sql
UPDATE stock
SET s_quantity   = CASE
                     WHEN s_quantity > :ol_quantity
                     THEN s_quantity - :ol_quantity
                     ELSE s_quantity - :ol_quantity + 91
                   END,
    s_ytd        = s_ytd + :ol_quantity,
    s_order_cnt  = s_order_cnt + 1,
    s_remote_cnt = s_remote_cnt + CASE
                                    WHEN :ol_supply_w_id <> :home_w_id THEN 1
                                    ELSE 0
                                  END
WHERE s_i_id = :ol_i_id
  AND s_w_id = :ol_supply_w_id;
```

### MySQL/MariaDB stored-procedure style example

```sql
UPDATE stock
SET s_quantity = no_s_quantity,
    s_ytd = s_ytd + no_ol_quantity,
    s_order_cnt = s_order_cnt + 1,
    s_remote_cnt = s_remote_cnt + IF(no_ol_supply_w_id <> no_w_id, 1, 0)
WHERE s_i_id = no_ol_i_id
  AND s_w_id = no_ol_supply_w_id;
```

### Notes
- `s_order_cnt` increments for every order line processed.
- `s_remote_cnt` increments only when supply warehouse differs from home warehouse.
- Keep this update in the same transaction scope as the rest of New-Order row changes.
