"""Concurrency tests: prove two simultaneous withdrawals cannot consume the
same earning. This is the question the review screening asks directly.

Two independent layers are tested:

  1. The *application flow* done correctly: each withdrawal runs in a
     transaction that locks the earning row with SELECT ... FOR UPDATE and
     checks status='available' before allocating. Concurrent attempts
     serialize; exactly one allocates, the other sees 'allocated' and backs
     off. (test_concurrent_withdrawals_serialize)

  2. The *database backstop* if the app check is skipped entirely: the UNIQUE
     index still lets only one allocation row exist for an earning; the loser
     gets a duplicate-key error rather than a second payout.
     (test_unique_index_is_the_backstop)

  3. That the row lock genuinely blocks a second FOR UPDATE.
     (test_for_update_blocks_second_reader)
"""
import threading
import pymysql

from conftest import connect, make_payment, make_earning, make_claim


def _seed_one_earning(clean_db):
    with clean_db.cursor() as cur:
        pay = make_payment(cur, "pi_conc", 20_000)
        earning = make_earning(cur, pay, seller_id=1, amount_cents=20_000)
        claim_a = make_claim(cur, seller_id=1)
        claim_b = make_claim(cur, seller_id=1)
    return earning, claim_a, claim_b


def test_concurrent_withdrawals_serialize(clean_db):
    earning, claim_a, claim_b = _seed_one_earning(clean_db)
    start = threading.Barrier(2)
    results = {}

    def withdraw(name, claim_id):
        conn = connect(autocommit=False)
        try:
            with conn.cursor() as cur:
                start.wait()
                conn.begin()
                # Lock the earning row and read its current status.
                cur.execute(
                    "SELECT status FROM seller_earnings WHERE id=%s FOR UPDATE",
                    (earning,),
                )
                status = cur.fetchone()["status"]
                if status != "available":
                    results[name] = "already_allocated"
                    conn.rollback()
                    return
                cur.execute(
                    "INSERT INTO source_allocations (claim_id, earning_id, seller_id, amount_cents) "
                    "VALUES (%s,%s,%s,%s)",
                    (claim_id, earning, 1, 20_000),
                )
                cur.execute(
                    "UPDATE seller_earnings SET status='allocated' WHERE id=%s",
                    (earning,),
                )
                conn.commit()
                results[name] = "ok"
        except Exception as exc:  # noqa: BLE001 - record and inspect in assertions
            results[name] = f"error:{type(exc).__name__}"
            conn.rollback()
        finally:
            conn.close()

    t1 = threading.Thread(target=withdraw, args=("A", claim_a))
    t2 = threading.Thread(target=withdraw, args=("B", claim_b))
    t1.start(); t2.start(); t1.join(); t2.join()

    outcomes = sorted(results.values())
    assert outcomes == ["already_allocated", "ok"], outcomes

    with clean_db.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS n FROM source_allocations WHERE earning_id=%s", (earning,))
        assert cur.fetchone()["n"] == 1


def test_unique_index_is_the_backstop(clean_db):
    """Even if both callers skip the FOR UPDATE status check and blindly insert,
    the UNIQUE index guarantees only one allocation row survives."""
    earning, claim_a, claim_b = _seed_one_earning(clean_db)
    start = threading.Barrier(2)
    results = {}

    def blind_insert(name, claim_id):
        conn = connect(autocommit=True)
        try:
            with conn.cursor() as cur:
                start.wait()
                cur.execute(
                    "INSERT INTO source_allocations (claim_id, earning_id, seller_id, amount_cents) "
                    "VALUES (%s,%s,%s,%s)",
                    (claim_id, earning, 1, 20_000),
                )
                results[name] = "ok"
        except pymysql.err.IntegrityError:
            results[name] = "duplicate_rejected"
        except Exception as exc:  # noqa: BLE001
            results[name] = f"error:{type(exc).__name__}"
        finally:
            conn.close()

    t1 = threading.Thread(target=blind_insert, args=("A", claim_a))
    t2 = threading.Thread(target=blind_insert, args=("B", claim_b))
    t1.start(); t2.start(); t1.join(); t2.join()

    outcomes = sorted(results.values())
    assert outcomes == ["duplicate_rejected", "ok"], outcomes


def test_for_update_blocks_second_reader(clean_db):
    """A held SELECT ... FOR UPDATE makes a second FOR UPDATE on the same row
    wait; with a short lock-wait timeout the second reader times out, proving
    the lock serializes access rather than letting both proceed."""
    earning, _, _ = _seed_one_earning(clean_db)

    holder = connect(autocommit=False)
    waiter = connect(autocommit=False)
    try:
        with holder.cursor() as hcur:
            holder.begin()
            hcur.execute("SELECT id FROM seller_earnings WHERE id=%s FOR UPDATE", (earning,))

        with waiter.cursor() as wcur:
            wcur.execute("SET SESSION innodb_lock_wait_timeout = 1")
            waiter.begin()
            timed_out = False
            try:
                wcur.execute("SELECT id FROM seller_earnings WHERE id=%s FOR UPDATE", (earning,))
                wcur.fetchall()
            except pymysql.err.OperationalError as exc:
                # 1205 = ER_LOCK_WAIT_TIMEOUT
                timed_out = exc.args[0] == 1205
            waiter.rollback()
            assert timed_out, "second FOR UPDATE should have timed out on the held lock"
        holder.rollback()
    finally:
        holder.close()
        waiter.close()
