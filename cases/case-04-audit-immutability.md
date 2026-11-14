# Case 04 — Audit history quietly rewritten

**Risk:** High — fraud becomes undetectable; disputes become unwinnable.

## The flaw
An `audit_events` table that is just an ordinary table can be `UPDATE`d or
`DELETE`d by anyone (or any compromised app credential) with write access. A
payout dispute or an internal fraud can then be erased after the fact.

## The exploit
```sql
UPDATE audit_events SET actor = 'someone_else' WHERE id = 42;  -- reassign blame
DELETE FROM audit_events WHERE event_type = 'withdrawal.approved';  -- erase it
```

## The fix
Two layers.

1. **Append-only triggers** reject mutation through normal DML:

```sql
CREATE TRIGGER trg_audit_no_update BEFORE UPDATE ON audit_events
FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'append-only';
CREATE TRIGGER trg_audit_no_delete BEFORE DELETE ON audit_events
FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'append-only';
```

2. **A hash chain** makes tampering that bypasses DML detectable. Each row
stores `row_hash = SHA2(prev_hash || row fields)`; altering or removing any
earlier row breaks every later hash, so re-walking the chain reveals it.

## Documented limit (not a silent gap)
Triggers do not stop `DROP TABLE`, `TRUNCATE`, `ALTER` or a `SUPER` user from
disabling the triggers. Real immutability also needs: least-privilege grants
(the app role gets `INSERT, SELECT` only — no `UPDATE/DELETE/DROP` on the audit
table) and off-box, write-once log shipping. The database enforces what it can;
the rest is an access-control decision called out in the review, not assumed.

## The tests
`tests/test_integrity.py::test_audit_update_is_blocked`
`tests/test_integrity.py::test_audit_delete_is_blocked`
`tests/test_integrity.py::test_audit_hash_chain_is_populated_and_linked`
