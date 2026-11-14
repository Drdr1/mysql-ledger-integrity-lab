-- ---------------------------------------------------------------------------
-- 03_audit_triggers.sql
-- Make audit_events append-only and tamper-evident (review scope item 4).
--
--   * BEFORE UPDATE / BEFORE DELETE triggers raise an error, so even an
--     account with UPDATE/DELETE privileges cannot rewrite or remove history
--     through normal DML.
--   * Each row carries row_hash = SHA2(prev_hash || canonical row fields).
--     prev_hash points at the previous row's hash, forming a chain: changing
--     or dropping any earlier row breaks the chain, so silent back-dating is
--     detectable with schema/verify_audit_chain.sql.
--
-- CONCURRENCY (why the chain-head table exists)
-- A naive trigger reads "the latest row_hash" with
--     SELECT row_hash FROM audit_events ORDER BY id DESC LIMIT 1
-- which takes no lock. Two simultaneous inserts can both read the same
-- previous hash and both link to it, FORKING the chain. Two layers prevent it:
--   1. Every append reads and advances a single-row chain head under
--      SELECT ... FOR UPDATE, so concurrent appends serialize on that row.
--   2. UNIQUE (prev_hash) on audit_events (01_tables.sql): if the head is ever
--      bypassed or stale, a second row claiming the same predecessor fails on
--      insert instead of silently branching.
-- Because the head update runs inside the inserting statement's transaction,
-- a failed or rolled-back insert also rolls back the head: no gaps.
--
-- NOTE (documented limitation, not a silent gap): triggers do not stop a user
-- with DROP/ALTER/TRUNCATE or SUPER from disabling them or dropping the table.
-- True immutability also needs least-privilege grants (no DDL on these tables
-- for the app role) plus off-box, write-once log shipping. See the README.
-- ---------------------------------------------------------------------------

-- Single-row pointer to the current chain tail. Carries the ownership marker
-- like every other object this migration creates.
CREATE TABLE IF NOT EXISTS ledger_audit_chain_head (
    id         TINYINT UNSIGNED NOT NULL,
    last_hash  CHAR(64)         NULL,
    updated_at DATETIME(6)      NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT ck_chain_head_singleton CHECK (id = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- Seed the head. On a re-run after an interrupted install where audit rows
-- already exist, seed it from the actual chain tail (the row nobody points
-- to), not NULL, so the chain continues instead of starting a second genesis.
INSERT IGNORE INTO ledger_audit_chain_head (id, last_hash)
SELECT 1, (
    SELECT a.row_hash
    FROM audit_events a
    LEFT JOIN audit_events nxt ON nxt.prev_hash = a.row_hash
    WHERE nxt.id IS NULL
    LIMIT 1
);

DROP TRIGGER IF EXISTS trg_audit_no_update;
DROP TRIGGER IF EXISTS trg_audit_no_delete;
DROP TRIGGER IF EXISTS trg_audit_hash_chain;

DELIMITER $$

-- Link each new row to the chain tail under a row lock, then advance the tail.
CREATE TRIGGER trg_audit_hash_chain
BEFORE INSERT ON audit_events
FOR EACH ROW
BEGIN
    DECLARE v_prev  CHAR(64);
    DECLARE v_heads INT DEFAULT 0;

    -- Serialize: a concurrent append blocks here until this one commits.
    SELECT COUNT(*), MAX(last_hash) INTO v_heads, v_prev
    FROM ledger_audit_chain_head
    WHERE id = 1
    FOR UPDATE;

    IF v_heads <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'audit chain head missing: run schema/00_install.sql';
    END IF;

    SET NEW.prev_hash = v_prev;  -- NULL only for the genesis row
    -- JSON is canonicalised with CAST(... AS JSON) so the hash computed here
    -- matches the one recomputed later from the stored (normalised) value.
    SET NEW.row_hash = SHA2(
        CONCAT_WS('|',
            COALESCE(v_prev, ''),
            NEW.event_type,
            NEW.entity_type,
            COALESCE(NEW.entity_id, ''),
            COALESCE(NEW.seller_id, ''),
            NEW.actor,
            COALESCE(CAST(CAST(NEW.payload AS JSON) AS CHAR), '')
        ), 256);

    UPDATE ledger_audit_chain_head
    SET last_hash = NEW.row_hash
    WHERE id = 1;
END$$

CREATE TRIGGER trg_audit_no_update
BEFORE UPDATE ON audit_events
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'audit_events is append-only: UPDATE is not permitted';
END$$

CREATE TRIGGER trg_audit_no_delete
BEFORE DELETE ON audit_events
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'audit_events is append-only: DELETE is not permitted';
END$$

DELIMITER ;
