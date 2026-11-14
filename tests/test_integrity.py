"""Relational + financial-integrity tests for the ledger schema.

Each test states the guarantee it proves, so the file doubles as a spec of
what the database enforces on its own.
"""
import pymysql
import pytest

from conftest import make_payment, make_earning, make_claim, allocate


def test_happy_path_allocation(clean_db):
    """A seller's own earning can be allocated to that seller's own claim."""
    with clean_db.cursor() as cur:
        pay = make_payment(cur, "pi_happy", 10_000)
        earning = make_earning(cur, pay, seller_id=1, amount_cents=10_000)
        claim = make_claim(cur, seller_id=1)
        allocate(cur, claim, earning, seller_id=1, amount_cents=10_000)
        cur.execute("SELECT COUNT(*) AS n FROM source_allocations")
        assert cur.fetchone()["n"] == 1


def test_double_allocation_is_rejected(clean_db):
    """GUARANTEE 1: the same earning cannot be consumed by two allocations.

    Enforced by UNIQUE KEY uq_allocation_earning (earning_id).
    """
    with clean_db.cursor() as cur:
        pay = make_payment(cur, "pi_double", 5_000)
        earning = make_earning(cur, pay, seller_id=1, amount_cents=5_000)
        claim_a = make_claim(cur, seller_id=1)
        claim_b = make_claim(cur, seller_id=1)
        allocate(cur, claim_a, earning, seller_id=1, amount_cents=5_000)
        with pytest.raises(pymysql.err.IntegrityError):
            allocate(cur, claim_b, earning, seller_id=1, amount_cents=5_000)


def test_cross_seller_allocation_is_rejected(clean_db):
    """GUARANTEE 2: seller B cannot allocate seller A's earning.

    Enforced by the composite FK (earning_id, seller_id) -> seller_earnings.
    Seller 2 claims earning that belongs to seller 1: the FK target
    (earning_id=E, seller_id=2) does not exist, so the insert fails.
    """
    with clean_db.cursor() as cur:
        pay = make_payment(cur, "pi_cross", 7_000)
        earning = make_earning(cur, pay, seller_id=1, amount_cents=7_000)
        claim_attacker = make_claim(cur, seller_id=2)
        with pytest.raises(pymysql.err.IntegrityError):
            allocate(cur, claim_attacker, earning, seller_id=2, amount_cents=7_000)


def test_payment_overallocation_is_rejected(clean_db):
    """A payment cannot fund earnings exceeding its amount.

    Enforced by trigger trg_earning_no_overallocate_ins.
    """
    with clean_db.cursor() as cur:
        pay = make_payment(cur, "pi_over", 10_000)
        make_earning(cur, pay, seller_id=1, amount_cents=6_000)
        with pytest.raises(pymysql.err.OperationalError):
            make_earning(cur, pay, seller_id=2, amount_cents=5_000)  # 6k+5k > 10k


def test_allocation_amount_must_match_earning(clean_db):
    """An allocation must consume the earning in full (no cent leakage).

    Enforced by trigger trg_allocation_amount_matches_earning.
    """
    with clean_db.cursor() as cur:
        pay = make_payment(cur, "pi_mismatch", 9_000)
        earning = make_earning(cur, pay, seller_id=1, amount_cents=9_000)
        claim = make_claim(cur, seller_id=1)
        with pytest.raises(pymysql.err.OperationalError):
            allocate(cur, claim, earning, seller_id=1, amount_cents=8_999)


def test_negative_and_zero_amounts_are_rejected(clean_db):
    """CHECK constraints keep all money amounts strictly positive."""
    with clean_db.cursor() as cur:
        with pytest.raises(pymysql.err.OperationalError):
            make_payment(cur, "pi_zero", 0)
        pay = make_payment(cur, "pi_neg_ok", 1_000)
        # amount_cents is UNSIGNED, so a negative literal is itself an error.
        with pytest.raises((pymysql.err.OperationalError, pymysql.err.DataError)):
            make_earning(cur, pay, seller_id=1, amount_cents=-100)


def test_audit_update_is_blocked(clean_db):
    """audit_events is append-only: UPDATE raises."""
    with clean_db.cursor() as cur:
        cur.execute(
            "INSERT INTO audit_events (event_type, entity_type, entity_id, seller_id, payload) "
            "VALUES ('withdrawal.approved','withdrawal_claim',1,1,JSON_OBJECT('amount',5000))"
        )
        with pytest.raises(pymysql.err.OperationalError):
            cur.execute("UPDATE audit_events SET actor = 'tamperer' WHERE id = 1")


def test_audit_delete_is_blocked(clean_db):
    """audit_events is append-only: DELETE raises."""
    with clean_db.cursor() as cur:
        cur.execute(
            "INSERT INTO audit_events (event_type, entity_type, entity_id, seller_id) "
            "VALUES ('withdrawal.paid','withdrawal_claim',1,1)"
        )
        with pytest.raises(pymysql.err.OperationalError):
            cur.execute("DELETE FROM audit_events WHERE id = 1")


def test_audit_hash_chain_is_populated_and_linked(clean_db):
    """Each audit row hashes in the previous row's hash (tamper-evident chain)."""
    with clean_db.cursor() as cur:
        for i in range(3):
            cur.execute(
                "INSERT INTO audit_events (event_type, entity_type, entity_id, seller_id) "
                "VALUES ('evt','claim',%s,1)",
                (i,),
            )
        cur.execute("SELECT id, prev_hash, row_hash FROM audit_events ORDER BY id")
        rows = cur.fetchall()
        assert rows[0]["prev_hash"] is None          # genesis row
        assert all(r["row_hash"] for r in rows)       # every row hashed
        assert rows[1]["prev_hash"] == rows[0]["row_hash"]
        assert rows[2]["prev_hash"] == rows[1]["row_hash"]
