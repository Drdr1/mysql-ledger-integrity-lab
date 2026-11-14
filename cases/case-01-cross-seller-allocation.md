# Case 01 — Earnings allocated to the wrong seller

**Risk:** High — one seller is paid from another seller's earnings.

## The flaw
A naive `source_allocations` table links a claim to an earning with two plain
foreign keys:

```sql
FOREIGN KEY (earning_id) REFERENCES seller_earnings (id),
FOREIGN KEY (claim_id)   REFERENCES withdrawal_claims (id)
```

Each FK is valid on its own, but nothing forces the earning and the claim to
belong to the **same** seller. The ownership check is left to application code.

## The exploit
Seller 2 creates a withdrawal claim and allocates seller 1's earning to it:

```sql
INSERT INTO source_allocations (claim_id, earning_id, seller_id, amount_cents)
VALUES (<seller2_claim>, <seller1_earning>, 2, 7000);
```

If the app forgets the ownership check on any one code path — a bulk import, an
admin tool, a new endpoint — seller 2 gets paid seller 1's money.

## The fix
Expose a composite unique key on each parent and bind the allocation to it, so
the database itself requires matching `seller_id`:

```sql
-- parents
UNIQUE KEY uq_earning_id_seller (id, seller_id)   -- on seller_earnings
UNIQUE KEY uq_claim_id_seller   (id, seller_id)   -- on withdrawal_claims

-- child
FOREIGN KEY (earning_id, seller_id) REFERENCES seller_earnings (id, seller_id),
FOREIGN KEY (claim_id,  seller_id) REFERENCES withdrawal_claims (id, seller_id)
```

Now the allocation's `seller_id` must equal the earning's owner **and** the
claim's owner. A cross-seller allocation points at an FK target that does not
exist and is rejected, on every code path, forever.

## The test
`tests/test_integrity.py::test_cross_seller_allocation_is_rejected`
