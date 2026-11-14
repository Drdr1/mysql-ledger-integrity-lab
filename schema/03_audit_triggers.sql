-- ---------------------------------------------------------------------------
-- 03_audit_triggers.sql
-- Make audit_events append-only and tamper-evident (review scope item 4).
--
--   * BEFORE UPDATE / BEFORE DELETE triggers raise an error, so even an
--     account with UPDATE/DELETE privileges cannot rewrite or remove history
--     through normal DML.
--   * Each row carries row_hash = SHA2(prev_hash || canonical row fields).
--     prev_hash points at the previous row's hash, forming a chain: changing
--     or dropping any earlier row breaks every hash after it, so silent
--     back-dating is detectable by re-walking the chain.
--
-- NOTE (documented limitation, not a silent gap): triggers do not stop a user
-- with DROP/ALTER/TRUNCATE or SUPER from disabling the triggers or dropping
-- the table. True immutability also needs least-privilege grants (no DDL on
-- the audit table for the app role) plus off-box log shipping. See the README.
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_audit_no_update;
DROP TRIGGER IF EXISTS trg_audit_no_delete;
DROP TRIGGER IF EXISTS trg_audit_hash_chain;

DELIMITER $$

-- Fill prev_hash/row_hash on insert so callers cannot forge the chain.
CREATE TRIGGER trg_audit_hash_chain
BEFORE INSERT ON audit_events
FOR EACH ROW
BEGIN
    DECLARE v_prev CHAR(64);

    SELECT row_hash INTO v_prev
    FROM audit_events
    ORDER BY id DESC
    LIMIT 1;

    SET NEW.prev_hash = v_prev;  -- NULL for the very first row
    SET NEW.row_hash = SHA2(
        CONCAT_WS('|',
            COALESCE(v_prev, ''),
            NEW.event_type,
            NEW.entity_type,
            COALESCE(NEW.entity_id, ''),
            COALESCE(NEW.seller_id, ''),
            NEW.actor,
            COALESCE(CAST(NEW.payload AS CHAR), '')
        ), 256);
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
