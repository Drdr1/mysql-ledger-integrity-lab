# Case 04 — Audit history rewritten, or forked by concurrent writers

**Risk:** High — fraud becomes undetectable; disputes become unwinnable.

## The flaw (two of them)
1. **Mutable history.** An ordinary `audit_events` table can be `UPDATE`d or
   `DELETE`d by any credential with write access.
2. **A racy hash chain.** A common "tamper-evident" design reads the latest hash
   with no lock:

   ```sql
   SELECT row_hash FROM audit_events ORDER BY id DESC LIMIT 1;  -- no lock
   ```

   Two simultaneous inserts both read the same previous hash and both link to
   it. The chain **forks**: two rows claim the same predecessor, and "one
   linear history" is no longer true. Under real load this is not theoretical.

## The exploits
```sql
UPDATE audit_events SET actor = 'someone_else' WHERE id = 42;        -- reassign blame
DELETE FROM audit_events WHERE event_type = 'withdrawal.approved';   -- erase it
-- and, with no lock on the chain tail, two concurrent writers fork the chain
```

## The fix
**Append-only triggers** reject `UPDATE` and `DELETE` through normal DML.

**A serialized hash chain**, in two layers:

1. Every append reads and advances a single-row chain head under a row lock,
   inside the inserting statement's transaction:

   ```sql
   SELECT COUNT(*), MAX(last_hash) INTO v_heads, v_prev
   FROM ledger_audit_chain_head WHERE id = 1 FOR UPDATE;   -- concurrent appends wait here
   SET NEW.prev_hash = v_prev;
   SET NEW.row_hash  = SHA2(CONCAT_WS('|', v_prev, <canonical row fields>), 256);
   UPDATE ledger_audit_chain_head SET last_hash = NEW.row_hash WHERE id = 1;
   ```

   A failed insert rolls back its own head update, so the head never points at
   a row that does not exist.

2. `UNIQUE KEY uq_audit_prev_hash (prev_hash)` is the backstop: if the head is
   ever bypassed or rewound, a second row claiming the same predecessor fails on
   insert instead of silently branching.

JSON payloads are hashed in canonical form (`CAST(... AS JSON)`), so the hash
recomputed later from the stored value matches the one written at insert.

**Detection:** `schema/verify_audit_chain.sql` re-walks the chain and reports
`hash_mismatch`, `broken_link`, `extra_genesis` or `forked_link`. An empty
result means the chain is intact.

## Documented limit (not a silent gap)
Triggers do not stop `DROP TABLE`, `TRUNCATE`, `ALTER` or a `SUPER` user from
disabling the triggers. Real immutability also needs least-privilege grants (the
app role gets `INSERT, SELECT` only on the audit table) and off-box, write-once
log shipping. The database enforces what it can; the rest is an access-control
decision called out in the review, not assumed.

## The tests
- `tests/test_integrity.py::test_audit_update_is_blocked`
- `tests/test_integrity.py::test_audit_delete_is_blocked`
- `tests/test_integrity.py::test_audit_hash_chain_is_populated_and_linked`
- `tests/test_audit_chain.py::test_concurrent_audit_inserts_do_not_fork_the_chain`
  (10 writers × 5 events at once → exactly one genesis, one linear chain of 50)
- `tests/test_audit_chain.py::test_stale_chain_head_cannot_fork_the_chain`
- `tests/test_audit_chain.py::test_verify_query_reports_an_intact_chain_as_clean`
