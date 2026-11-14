# Case 05 — A half-installed registry, and whose objects are these?

**Risk:** Medium–High — a financial schema left partly built and reported as
"installed", or a recovery script that damages objects it never owned.

## The flaw
In MySQL, **every DDL statement implicitly commits and is not transactional.**

```sql
START TRANSACTION;
CREATE TABLE payments ...;
CREATE TABLE seller_earnings ...;   -- fails here
ROLLBACK;                           -- does NOT undo the first CREATE
```

An interrupted install leaves some tables, some triggers, and no rollback. Two
naive recoveries make it worse:

- **"Drop and start over"** by name or pattern can delete a pre-existing table
  that merely shares a name (`payments` is a very common name).
- **`CREATE TABLE IF NOT EXISTS`** silently *skips* a same-named table with a
  different structure, so a "complete" install can be sitting on someone
  else's schema. A check that only counts table names would approve it.

## The fix
`schema/00_install.sql` makes ownership a recorded fact rather than a guess:

1. **Ownership marker.** Every object the migration creates carries
   `COMMENT='owner=ledger-registry;v=1'`.
2. **Preflight, before anything is created.** If any managed name is already
   taken by an object *without* the marker (or a managed trigger name is used
   on a table we do not own), the installer stops with an error and changes
   nothing.
3. **Migration log.** `ledger_migration_log` records each completed step
   (`01_tables`, `02_integrity_triggers`, `03_audit_triggers`, `verified`), so
   after an interruption you can see exactly how far it got.
4. **Definition checks, not name checks.** The final assertion verifies the
   headline unique index covers exactly `earning_id`, the composite owner keys
   and both ownership FKs have the right columns and parents, every money
   column is `BIGINT UNSIGNED`, all five triggers sit on the right tables, and
   the audit chain head exists.
5. **No drops.** The installer never drops a table.

## Recovery procedure
1. Run `schema/inventory.sql`. Every managed name is reported as `owned`,
   `missing`, or `FOREIGN - do not touch`.
2. If anything is `FOREIGN`, stop. The installer will refuse anyway; resolve it
   with whoever owns that object. Never modify or drop it.
3. Otherwise re-run `schema/00_install.sql`. It creates only what is missing,
   only on names proven to be ours or free, then verifies definitions.
4. Check `ledger_migration_log` shows the `verified` step. Only then is the
   registry "Approved for empty staging installation."

The only artifact a refused run leaves behind is the `ledger_preflight`
procedure itself (MySQL can only `SIGNAL` from a stored program); it holds no
data and is safe to drop.

## The tests (CI)
- Installer run **twice** on a clean database: the second run succeeds.
- **Conflict:** a database already containing a foreign `payments` table makes
  the installer fail, the foreign table keeps its columns and row, and no other
  table or trigger is created.
- **Interruption:** only the tables step is run, then the installer completes the
  rest and logs `verified`.

See `.github/workflows/ci.yml`.
