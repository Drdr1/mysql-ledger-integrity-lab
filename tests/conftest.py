"""Shared fixtures for the ledger integrity tests.

Connection settings come from environment variables so the same suite runs
locally and in CI:

    DB_HOST (default 127.0.0.1), DB_PORT (3306), DB_USER (root),
    DB_PASSWORD (default empty), DB_NAME (default ledger)

The schema is expected to be installed already (CI runs
`mysql < schema/00_install.sql` before pytest). Each test starts from clean
tables via the `clean_db` fixture.
"""
import os
import pymysql
import pytest

DB_CONFIG = dict(
    host=os.environ.get("DB_HOST", "127.0.0.1"),
    port=int(os.environ.get("DB_PORT", "3306")),
    user=os.environ.get("DB_USER", "root"),
    password=os.environ.get("DB_PASSWORD", ""),
    database=os.environ.get("DB_NAME", "ledger"),
    autocommit=True,
    charset="utf8mb4",
    cursorclass=pymysql.cursors.DictCursor,
)

LEDGER_TABLES = [
    "allocation_evidence",
    "source_allocations",
    "withdrawal_claims",
    "seller_earnings",
    "payments",
    "audit_events",
]


def connect(**overrides):
    cfg = dict(DB_CONFIG)
    cfg.update(overrides)
    return pymysql.connect(**cfg)


@pytest.fixture(scope="session")
def db():
    conn = connect()
    yield conn
    conn.close()


@pytest.fixture
def clean_db(db):
    """Truncate every ledger table before each test.

    FOREIGN_KEY_CHECKS is disabled so children/parents can be truncated in any
    order. audit_events is append-only (DELETE is blocked by a trigger) but
    TRUNCATE is DDL and does not fire row triggers, so it resets cleanly.
    """
    with db.cursor() as cur:
        cur.execute("SET FOREIGN_KEY_CHECKS = 0")
        for table in LEDGER_TABLES:
            cur.execute(f"TRUNCATE TABLE {table}")
        cur.execute("SET FOREIGN_KEY_CHECKS = 1")
        # The audit chain restarts from genesis, so the chain head must too.
        cur.execute("UPDATE ledger_audit_chain_head SET last_hash = NULL WHERE id = 1")
    return db


# --- small helpers the tests build scenarios from -------------------------

def make_payment(cur, external_ref, amount_cents, status="captured"):
    cur.execute(
        "INSERT INTO payments (external_ref, amount_cents, status) VALUES (%s, %s, %s)",
        (external_ref, amount_cents, status),
    )
    return cur.lastrowid


def make_earning(cur, payment_id, seller_id, amount_cents, status="available"):
    cur.execute(
        "INSERT INTO seller_earnings (payment_id, seller_id, amount_cents, status) "
        "VALUES (%s, %s, %s, %s)",
        (payment_id, seller_id, amount_cents, status),
    )
    return cur.lastrowid


def make_claim(cur, seller_id, status="pending"):
    cur.execute(
        "INSERT INTO withdrawal_claims (seller_id, status) VALUES (%s, %s)",
        (seller_id, status),
    )
    return cur.lastrowid


def allocate(cur, claim_id, earning_id, seller_id, amount_cents):
    cur.execute(
        "INSERT INTO source_allocations (claim_id, earning_id, seller_id, amount_cents) "
        "VALUES (%s, %s, %s, %s)",
        (claim_id, earning_id, seller_id, amount_cents),
    )
    return cur.lastrowid
