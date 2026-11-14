# Case 05 — A half-installed registry

**Risk:** Medium–High — a financial schema left in an inconsistent, partly
built state, reported as "installed."

## The flaw
In MySQL, **every DDL statement implicitly commits and is not transactional.**
You cannot do:

```sql
START TRANSACTION;
CREATE TABLE payments ...;
CREATE TABLE seller_earnings ...;   -- fails here
ROLLBACK;                           -- does NOT undo the first CREATE
```

If an install of six tables plus triggers is interrupted at statement 4, you
are left with four tables, some foreign-key targets missing, and no automatic
rollback. Worse, a deploy script that only checks "did mysql exit 0" can report
success on a partial registry.

## The fix
1. **Strict ordering** — parents before children, so FK targets always exist
   at the moment a child table is created.
2. **Idempotent objects** — `CREATE TABLE IF NOT EXISTS`, `DROP TRIGGER IF
   EXISTS` before each `CREATE TRIGGER`. Re-running the installer after a
   partial failure *completes* it instead of erroring.
3. **A completeness assertion** — after creating everything, the installer
   counts the expected tables, headline unique indexes and triggers in
   `information_schema` and `SIGNAL`s an error if any are missing. "It ran" is
   not allowed to mean "it is correct."

See `schema/00_install.sql` (the `_assert_install_complete` procedure).

## Recovery procedure
1. Do **not** drop what exists. Re-run `schema/00_install.sql`; the `IF NOT
   EXISTS` guards fill in only the missing objects.
2. The final assertion confirms all six tables, the three unique guards and the
   five triggers are present, or it fails with the specific gap.
3. Only then is the registry "Approved for empty staging installation."

## The test
CI runs the installer **twice** in a row; the second run must succeed and pass
the assertion, proving the installer is safe to re-run after an interruption.
See `.github/workflows/ci.yml`.
