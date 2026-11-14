# Sample Independent Review — Seller Payout Registry (MySQL/InnoDB)

> **What this is.** A sample of my review deliverable, applied to my own
> demonstration schema in this repository, so a client can see exactly what
> they would receive before engaging me. Same structure, same severity scale,
> same verdict options I use for client work. The schema reviewed is the
> repository at commit `e88dbff`. Findings are deliberately **not** fixed in
> `schema/`, so this report keeps matching the code it describes; the
> corrections live in `sample-review/corrections.sql` and are proven in CI.

| | |
|---|---|
| **Subject** | Six-table seller payout registry: `payments`, `seller_earnings`, `withdrawal_claims`, `source_allocations`, `allocation_evidence`, `audit_events` (+ `ledger_audit_chain_head`, `ledger_migration_log`) |
| **Engine** | MySQL 8.0 (InnoDB), verified on 8.0 in CI |
| **Basis** | SQL definitions, installer, documentation, and test results only. No production access. |
| **Reviewer** | Ahmed Darder (DerOps) |
| **Verdict** | **Changes Required.** Three high-severity findings must be fixed before any payout logic relies on this schema. All recommended corrections are additive and CI-verified; once applied and the installer assertion re-passes, the registry is suitable for **empty staging installation**. |

---

## 1. Executive summary

The core integrity design is sound. The two guarantees that matter most hold at the database level and are tested under concurrency:

- **No double consumption.** `UNIQUE (earning_id)` on `source_allocations` means an earning can appear in at most one allocation.
- **No cross-seller allocation.** Composite foreign keys on `(earning_id, seller_id)` and `(claim_id, seller_id)` mean an earning can only attach to its own seller's claim.

The weaknesses sit around those guarantees rather than in them:

- **Write-path gaps.** Guards that fire on `INSERT` are bypassed on `UPDATE`.
- **Missing state preconditions.** An earning funded by a refunded payment, or already reversed, can still be allocated.
- **Derived values that can drift.** The claim total and the earning status are not tied to the allocations that justify them.

| ID | Severity | Finding | DB-enforceable | Correction |
|----|----------|---------|----------------|------------|
| F-01 | **High** | Earnings funded by an uncaptured or refunded payment can be allocated | Yes | `trg_allocation_preconditions` |
| F-02 | **High** | Allocation ignores earning status and claim status; earning status is not set atomically | Yes | `trg_allocation_preconditions`, `trg_allocation_apply` |
| F-03 | **High** | Over-allocation and amount-match guards fire on INSERT only; UPDATE paths bypass them | Yes | `trg_earning_guard_upd`, `trg_payment_amount_guard`, `trg_allocation_no_update` |
| F-04 | Medium | `withdrawal_claims.total_cents` is an unenforced cache that can diverge from its allocations | Partly | `trg_allocation_apply`, `trg_allocation_release` + reconciliation query |
| F-05 | Medium | Allocations can be deleted after a claim is approved or paid | Yes | `trg_allocation_delete_guard`, `trg_allocation_release` |
| F-06 | Low | Case- and accent-insensitive collation on `external_ref` can reject a distinct provider ID | Yes | `ALTER … COLLATE ascii_bin` |
| F-07 | Medium | Audit immutability and the chain head depend on database privileges not defined in the schema | No (grants/ops) | Grant model, §5 |
| F-08 | Low | Claim status transitions are not enforced (e.g. `paid` → `draft`) | Yes | Recommendation |
| F-09 | Optional | No currency on earnings/allocations; mixed-currency sums are undetectable | Yes | Recommendation |
| F-10 | Optional | Multi-earning approvals need a consistent lock order to avoid deadlocks | No (app) | Recommendation, §3 |

---

## 2. Findings

### F-01 — High — Earnings from uncaptured or refunded payments are allocatable
**Where:** `source_allocations` insert path; `payments.status`.
**Issue:** Nothing checks the funding payment's status when an earning is allocated. A payment can be `pending`, `refunded` or `partially_refunded` while its earnings remain withdrawable.
**Impact:** The platform pays sellers for money it never captured or has returned to the buyer. This is direct loss.
**Reproduce (on `e88dbff`):**
```sql
INSERT INTO payments (external_ref, amount_cents, status) VALUES ('pi_r', 500, 'refunded');
INSERT INTO seller_earnings (payment_id, seller_id, amount_cents) VALUES (LAST_INSERT_ID(), 1, 500);
-- allocating this earning into seller 1's open claim succeeds
```
**Correction:** `trg_allocation_preconditions` requires the funding payment to be `captured`. **Application side:** a reversal workflow is still needed for refunds that arrive *after* allocation or payout. That decision is a business rule, not schema.

### F-02 — High — Allocation ignores earning and claim state
**Where:** `source_allocations` insert path; `seller_earnings.status`; `withdrawal_claims.status`.
**Issue:** An earning with status `reversed` or `paid` can be allocated, and allocations can be added to claims that are already `approved`, `paid`, `rejected` or `cancelled`. Separately, setting the earning to `allocated` is left to the caller, so an allocation can exist while the earning still reads `available`, or the reverse.
**Impact:** Reversed earnings get paid out, approved claims grow after approval, and the status column stops being trustworthy for reporting and reconciliation.
**Correction:** `trg_allocation_preconditions` (earning must be `available`, claim must be `draft` or `pending`, earning row locked) plus `trg_allocation_apply`, which marks the earning `allocated` in the same statement.

### F-03 — High — INSERT-only guards are bypassed on UPDATE
**Where:** `trg_earning_no_overallocate_ins`, `trg_allocation_amount_matches_earning`.
**Issue:** Both guards are `BEFORE INSERT` only. Each of these succeeds:
```sql
UPDATE seller_earnings SET amount_cents = amount_cents + 10000 WHERE id = ?;  -- over-allocates the payment
UPDATE payments SET amount_cents = 1 WHERE id = ?;                            -- payment below its earnings
UPDATE source_allocations SET earning_id = ? WHERE id = ?;                    -- re-points an allocation
```
**Impact:** Every invariant the INSERT triggers enforce can be undone by a later UPDATE, from an admin tool, a script, or a bug.
**Correction:** `trg_earning_guard_upd` re-checks over-allocation on UPDATE and freezes an allocated earning's amount, payment and seller. `trg_payment_amount_guard` stops a payment dropping below its assigned earnings. `trg_allocation_no_update` makes allocations immutable (remove and re-add while the claim is open).

### F-04 — Medium — Claim total is an unenforced cache
**Issue:** `withdrawal_claims.total_cents` is never derived from allocations. If approval or payout reads it, a stale or edited value pays the wrong amount.
**Correction:** `trg_allocation_apply` and `trg_allocation_release` maintain it on every allocation change. **Application side:** never write `total_cents` directly, and reconcile before approval:
```sql
SELECT c.id, c.total_cents, COALESCE(SUM(a.amount_cents), 0) AS allocated
FROM withdrawal_claims c
LEFT JOIN source_allocations a ON a.claim_id = c.id
GROUP BY c.id, c.total_cents
HAVING c.total_cents <> allocated;   -- must return no rows
```

### F-05 — Medium — Allocations deletable after approval
**Issue:** `DELETE` on `source_allocations` is unrestricted (it is blocked only when evidence rows reference it). Deleting an allocation from an approved or paid claim silently changes what was paid, with no state release and no audit event.
**Correction:** `trg_allocation_delete_guard` blocks deletes on non-open claims. `trg_allocation_release` returns the earning to `available` and reduces the total when removal is legitimate.

### F-06 — Low — Provider reference collation
**Issue:** `payments.external_ref` uses `utf8mb4_0900_ai_ci`, which is case- and accent-insensitive. Provider IDs are case-sensitive, so two distinct IDs differing only in case collide on the UNIQUE key and the second is rejected as a duplicate.
**Correction:** `MODIFY external_ref VARCHAR(191) CHARACTER SET ascii COLLATE ascii_bin`.

### F-07 — Medium — Audit immutability depends on privileges outside the schema
**Issue:** The append-only triggers and the hash chain are correct, but any account with `TRIGGER`, `DROP`, `ALTER`, `TRUNCATE` or `SUPER` can disable or bypass them. An account with direct `UPDATE` on `ledger_audit_chain_head` can rewind the head. The `UNIQUE (prev_hash)` backstop prevents a fork, but a rewound head makes new audit inserts fail, so it can be used to block auditing.
**Recommendation (operations):** the application role gets `INSERT, SELECT` on `audit_events` and no privileges at all on `ledger_audit_chain_head`. Triggers run with their definer's privileges, so the chain still advances. No DDL or `TRIGGER` privilege goes to the application role. Ship audit rows off-box to write-once storage, and run `schema/verify_audit_chain.sql` on a schedule.

### F-08 — Low — Claim status transitions unenforced
Any status can be set to any other (`paid` → `draft`). **Recommendation:** a `BEFORE UPDATE` trigger allowing only `draft→pending→approved→paid` and `draft|pending→rejected|cancelled`, with every transition written to `audit_events`.

### F-09 — Optional — Currency
`payments.currency` exists, but earnings and allocations carry none, so a claim could sum amounts in different currencies without detection. **Recommendation:** for a single-currency platform, enforce one fixed value with a `CHECK`. For multi-currency, add `currency` to earnings, allocations and claims, and require it to match through the composite keys.

### F-10 — Optional — Lock ordering
See §3.

---

## 3. Concurrency assessment

| Scenario | Result | Evidence |
|---|---|---|
| Two approvals consume the same earning at once | **Safe.** Serialized by `SELECT … FOR UPDATE`; exactly one allocates | `tests/test_concurrency.py::test_concurrent_withdrawals_serialize` |
| A code path skips the lock and inserts blindly | **Safe.** `UNIQUE (earning_id)` rejects the second row | `test_unique_index_is_the_backstop` |
| Held row lock blocks a second locker | **Confirmed** (lock-wait timeout, error 1205) | `test_for_update_blocks_second_reader` |
| Concurrent earnings against one payment | **Safe.** Payment row locked in the over-allocation trigger | trigger design (§F-03 extends it to UPDATE) |
| Concurrent audit writers | **Safe.** One linear chain from 10 writers × 5 events | `tests/test_audit_chain.py` |
| Multi-earning approval locking earnings in arbitrary order | **Deadlock risk** (F-10) | design review |

**F-10 recommendation:** when one approval locks several earnings, lock them in a single deterministic order (`SELECT … WHERE id IN (…) ORDER BY id FOR UPDATE`) in one statement, and retry the whole transaction on deadlock (error 1213). InnoDB resolves deadlocks by rolling one transaction back. That is correct behaviour, but only if the application retries cleanly instead of surfacing a partial approval.

---

## 4. Installation and recovery procedure

MySQL DDL auto-commits and cannot be rolled back, so the install is designed to be safe to interrupt and re-run rather than "all or nothing".

1. **Before install:** run `schema/inventory.sql`. Every managed name must be `missing` or `owned`. If any is `FOREIGN`, stop and resolve it with the object's owner. The installer refuses to run in that state and changes nothing (proven in CI).
2. **Install:** `mysql ledger < schema/00_install.sql`, then `mysql ledger < sample-review/corrections.sql`.
3. **Verify:** the installer's final assertion checks definitions (key columns, ownership foreign keys, money column types, trigger placement, chain head), not just names. `ledger_migration_log` must show the `verified` step.
4. **If interrupted:** do not drop anything. Re-run the same two commands. `IF NOT EXISTS` and `DROP … IF EXISTS` guards create only what is missing, and only on names proven to be owned or free. Re-check step 3.
5. **Never** recover by dropping tables by name or pattern. A refused run leaves only the empty `ledger_preflight` procedure, which is safe to drop.

---

## 5. What the database enforces vs. what the application must

**Database (after corrections):**
- positive integer-cent amounts
- seller ownership
- single consumption of each earning
- no over-allocation on insert or update
- immutable allocations
- allocation preconditions (captured payment, available earning, open claim)
- atomic status and total maintenance
- append-only, fork-proof audit chain

**Application and operations:**
- the refund and reversal workflow after payout (F-01)
- lock ordering and deadlock retry (F-10)
- the privilege model and off-box audit shipping (F-07)
- claim approval rules beyond status (KYC, minimums, holds)
- payment-provider webhook signature verification and idempotency

Approval of this schema covers creating the empty registry on staging only. It does not authorize payouts or certify the wider payment system.

---

## 6. Verdict

**Changes Required.** Fix F-01, F-02 and F-03 before any payout logic depends on this schema. F-04, F-05 and F-06 are strongly recommended, and their corrections ship in the same script. F-07 needs a grant decision from the operator. With `sample-review/corrections.sql` applied and the installer assertion passing, the registry is **approved for empty staging installation**.
