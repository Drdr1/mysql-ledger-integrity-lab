"""Audit hash-chain integrity under concurrency.

Question this answers: can two simultaneous audit inserts create competing
hash-chain entries (a fork)? They must not. Appends serialize on a locked
chain-head row, and UNIQUE (prev_hash) rejects any row that tries to reuse a
predecessor if the head is ever bypassed or stale.
"""
import pathlib
import threading

import pymysql
import pytest

from conftest import connect

VERIFY_SQL = (
    pathlib.Path(__file__).resolve().parent.parent / "schema" / "verify_audit_chain.sql"
).read_text().strip().rstrip(";")

THREADS = 10
EVENTS_PER_THREAD = 5


def _insert_event(cur, n, payload=True):
    if payload:
        # Keys deliberately unsorted: hashing must use the canonical JSON form.
        cur.execute(
            "INSERT INTO audit_events (event_type, entity_type, entity_id, seller_id, payload) "
            "VALUES ('withdrawal.approved','withdrawal_claim',%s,1,"
            "JSON_OBJECT('zeta', %s, 'amount', 5000, 'alpha', 'x'))",
            (n, n),
        )
    else:
        cur.execute(
            "INSERT INTO audit_events (event_type, entity_type, entity_id, seller_id) "
            "VALUES ('withdrawal.paid','withdrawal_claim',%s,1)",
            (n,),
        )


def _walk_chain(rows):
    """Follow prev_hash links from genesis; return the ordered chain."""
    by_prev = {}
    for r in rows:
        assert r["prev_hash"] not in by_prev, f"fork: two rows share prev_hash {r['prev_hash']}"
        by_prev[r["prev_hash"]] = r
    chain, cursor = [], None
    while cursor in by_prev:
        row = by_prev[cursor]
        chain.append(row)
        cursor = row["row_hash"]
    return chain


def test_concurrent_audit_inserts_do_not_fork_the_chain(clean_db):
    """Many writers appending at once still produce ONE linear chain."""
    start = threading.Barrier(THREADS)
    errors = []

    def writer(tid):
        conn = connect(autocommit=True)
        try:
            with conn.cursor() as cur:
                start.wait()
                for i in range(EVENTS_PER_THREAD):
                    _insert_event(cur, tid * 100 + i, payload=(i % 2 == 0))
        except Exception as exc:  # noqa: BLE001
            errors.append(repr(exc))
        finally:
            conn.close()

    threads = [threading.Thread(target=writer, args=(t,)) for t in range(THREADS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == [], errors

    with clean_db.cursor() as cur:
        cur.execute("SELECT id, prev_hash, row_hash FROM audit_events")
        rows = cur.fetchall()

    total = THREADS * EVENTS_PER_THREAD
    assert len(rows) == total
    assert sum(1 for r in rows if r["prev_hash"] is None) == 1, "exactly one genesis row"
    chain = _walk_chain(rows)
    assert len(chain) == total, "every row is reachable on a single linear chain"

    # The head points at the true tail.
    with clean_db.cursor() as cur:
        cur.execute("SELECT last_hash FROM ledger_audit_chain_head WHERE id = 1")
        assert cur.fetchone()["last_hash"] == chain[-1]["row_hash"]


def test_verify_query_reports_an_intact_chain_as_clean(clean_db):
    """schema/verify_audit_chain.sql returns no problems for a valid chain,
    including rows with JSON payloads (canonical hashing round-trips)."""
    with clean_db.cursor() as cur:
        for i in range(6):
            _insert_event(cur, i, payload=(i % 2 == 0))
        cur.execute(VERIFY_SQL)
        assert cur.fetchall() == ()


def test_stale_chain_head_cannot_fork_the_chain(clean_db):
    """If the head is ever rewound or bypassed, UNIQUE (prev_hash) refuses the
    competing entry instead of letting the chain branch, and the failed insert
    rolls back its own head update."""
    with clean_db.cursor() as cur:
        _insert_event(cur, 1, payload=False)
        _insert_event(cur, 2, payload=False)
        cur.execute("SELECT row_hash FROM audit_events ORDER BY id")
        first_hash, second_hash = [r["row_hash"] for r in cur.fetchall()]

        # Simulate a corrupted / bypassed head pointing back at row 1.
        cur.execute(
            "UPDATE ledger_audit_chain_head SET last_hash = %s WHERE id = 1", (first_hash,)
        )
        with pytest.raises(pymysql.err.IntegrityError):
            _insert_event(cur, 3, payload=False)  # would claim row 1 as predecessor again

        cur.execute("SELECT COUNT(*) AS n FROM audit_events")
        assert cur.fetchone()["n"] == 2
        cur.execute("SELECT last_hash FROM ledger_audit_chain_head WHERE id = 1")
        assert cur.fetchone()["last_hash"] == first_hash  # unchanged by the failed insert
        assert second_hash != first_hash
