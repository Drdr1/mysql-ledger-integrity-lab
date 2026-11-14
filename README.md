# MySQL / InnoDB Ledger Integrity Lab

A small, runnable reference for the questions that matter when you review a
**financial payout schema on MySQL/InnoDB**: can the same earning be paid
twice, can one seller be paid from another's earnings, can a payment fund more
than it collected, is the audit trail tamper-evident, and does a half-finished
install get caught instead of approved.

It is built as a **casebook**: each failure mode is one document — the flaw, an
exploit, the fix, and a test that proves the fix holds. The schema in
`schema/` is the fixed version; the tests in `tests/` run the exploits against
it and assert they are rejected.

> Scope note: this is a focused teaching/reference lab with a synthetic schema,
> not a drop-in production system. It mirrors the structure of a real
> multi-vendor auction payout registry (payments → seller earnings →
> withdrawal claims → allocations → evidence + audit).

## The six cases

| # | Case | Guarantee | Enforced by |
|---|------|-----------|-------------|
| 01 | [Cross-seller allocation](cases/case-01-cross-seller-allocation.md) | an earning can only join a claim of the same seller | composite FKs |
| 02 | [Double allocation](cases/case-02-double-allocation.md) | an earning is consumed at most once | `UNIQUE (earning_id)` |
| 03 | [Payment over-allocation](cases/case-03-payment-overallocation.md) | earnings never exceed the payment | `BEFORE INSERT` trigger |
| 04 | [Audit immutability](cases/case-04-audit-immutability.md) | audit log is append-only, tamper-evident, and cannot fork under concurrent writers | triggers + locked chain head + `UNIQUE (prev_hash)` |
| 05 | [Partial-DDL recovery](cases/case-05-partial-ddl-recovery.md) | a half-built registry is caught, and pre-existing objects are never touched | ownership markers + preflight + migration log + definition checks |
| 06 | [Concurrent withdrawal race](cases/case-06-concurrent-withdrawal-race.md) | two simultaneous approvals can't double-pay | `SELECT … FOR UPDATE` + unique index |

## Schema

```
schema/
  01_tables.sql              6 InnoDB tables, integer-cent money, composite keys
  02_integrity_triggers.sql  cross-row invariants (over-allocation, amount match)
  03_audit_triggers.sql      append-only audit + serialized SHA-256 hash chain
  00_install.sql             ownership-aware installer: preflight, migration log,
                             definition-level completeness assertion
  verify_audit_chain.sql     read-only tamper check (empty result = intact)
  inventory.sql              read-only: each managed name is owned / missing / FOREIGN
```

Requires **MySQL 8.0.16+** — `CHECK` constraints are only enforced from that
version. On older MySQL they parse but are silently ignored, which this lab
treats as a finding, not a pass.

## Run it

```bash
docker compose up -d
# wait for healthy, then:
mysql -h 127.0.0.1 -uroot -prootpw ledger < schema/00_install.sql
DB_PASSWORD=rootpw pytest -v tests/
docker compose down -v
```

Or `make all`. CI (`.github/workflows/ci.yml`) runs the whole thing against a
`mysql:8.0` service on every push, and also proves three installer properties:
it is safe to re-run, it completes an interrupted install, and it refuses to
run over a pre-existing table it does not own (leaving that table untouched).

## What the database enforces vs what the application must

A deliberate theme: not every protection belongs in the database, and saying so
is part of a good review.

**Enforced in the database (this lab):**
- Positive, integer-cent amounts (`CHECK`, `UNSIGNED`).
- Seller ownership of allocations (composite foreign keys).
- No double-consumption of an earning (unique index).
- No over-allocation of a payment (trigger with row lock).
- Allocation amount equals the earning (trigger).
- Append-only, tamper-evident audit that cannot fork under concurrent writers
  (triggers + locked chain head + `UNIQUE (prev_hash)`).
- Concurrency safety for withdrawals (`FOR UPDATE` + unique index).

**Must live in the application / operations (documented, not assumed):**
- Keeping `withdrawal_claims.total_cents` in step with its allocations
  (a derived cache).
- Refund / reversal accounting once money has left the platform.
- Real audit immutability against `DROP`/`TRUNCATE`/`SUPER` — needs
  least-privilege grants and off-box, write-once log shipping.
- Payment-provider (Stripe/Klarna/Affirm) state, webhook signature
  verification and idempotency.

## Layout
```
schema/   fixed schema + installer
cases/    one markdown case per failure mode
tests/    pytest + PyMySQL: integrity, withdrawal-concurrency and audit-chain suites
```
