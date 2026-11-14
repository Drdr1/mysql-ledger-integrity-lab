# Case 06 — Two withdrawals approved at the same instant

**Risk:** Critical — the double-payout of Case 02, but through a race the app's
own check fails to catch.

## The flaw
The application "checks then acts":

```
1. SELECT status FROM seller_earnings WHERE id = E;   -- reads 'available'
2. if available: INSERT allocation; UPDATE earning SET status='allocated';
```

With two approvals running at once and no row lock, **both** read `available`
at step 1 before either writes at step 2. Both proceed. Without a database
backstop, both allocations are created — the earning is paid twice.

## The fix — two independent layers

**Layer 1: serialize the check with a row lock.** Do the read inside the
transaction with `FOR UPDATE`:

```sql
START TRANSACTION;
SELECT status FROM seller_earnings WHERE id = E FOR UPDATE;  -- 2nd txn blocks here
-- if available: insert allocation, set status='allocated'
COMMIT;
```

The second transaction blocks at the `SELECT ... FOR UPDATE` until the first
commits, then reads `allocated` and backs off. Exactly one allocation.

**Layer 2: the unique index is the backstop.** Even if a code path skips the
lock-and-check entirely and blindly inserts, `UNIQUE (earning_id)` (Case 02)
lets only one allocation row exist; the loser gets a duplicate-key error instead
of a second payout.

Defence in depth: the lock makes the correct path clean; the unique index makes
the incorrect path safe.

## How to verify (what the review asks)
Open two concurrent transactions against the same earning and confirm one
succeeds and the other is blocked and then rejected — not both committing.

## The tests
`tests/test_concurrency.py::test_concurrent_withdrawals_serialize`
`tests/test_concurrency.py::test_unique_index_is_the_backstop`
`tests/test_concurrency.py::test_for_update_blocks_second_reader`
