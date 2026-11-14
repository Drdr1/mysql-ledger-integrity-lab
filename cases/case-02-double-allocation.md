# Case 02 — The same earning paid out twice

**Risk:** Critical — direct, repeatable loss of funds.

## The flaw
`source_allocations` has no unique constraint on `earning_id`. Nothing stops
the same earning from being attached to two different withdrawal claims, so it
can be paid out twice.

## The exploit
```sql
INSERT INTO source_allocations (claim_id, earning_id, seller_id, amount_cents)
VALUES (<claim_a>, <earning>, 1, 5000);
INSERT INTO source_allocations (claim_id, earning_id, seller_id, amount_cents)
VALUES (<claim_b>, <earning>, 1, 5000);   -- same earning, second claim
```

Both succeed; the seller withdraws the same 5,000 cents through two claims. The
race version of this (two requests at the same instant) is Case 06.

## The fix
Make "an earning is consumed at most once" a database invariant:

```sql
UNIQUE KEY uq_allocation_earning (earning_id)
```

The second insert now fails with a duplicate-key error regardless of timing,
application logic, or how many endpoints exist. This single index is the
hard backstop behind the whole payout system.

## The test
`tests/test_integrity.py::test_double_allocation_is_rejected`
(and the concurrent form in `tests/test_concurrency.py`)
