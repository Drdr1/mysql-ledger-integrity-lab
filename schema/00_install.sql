-- ---------------------------------------------------------------------------
-- 00_install.sql  —  ordered, re-runnable installer for the ledger registry.
--
-- WHY THIS FILE EXISTS
-- In MySQL every DDL statement implicitly commits and is NOT transactional:
-- you cannot wrap CREATE TABLE ... in a transaction and ROLLBACK the lot if
-- statement 4 of 6 fails. An interrupted install therefore leaves a PARTIAL
-- registry (some tables, some constraints), which is dangerous for a financial
-- schema. (Review scope item 5.)
--
-- Mitigations used here:
--   * Strict ordering: parents before children, so FK targets always exist.
--   * Every object uses IF NOT EXISTS / DROP IF EXISTS, so re-running after a
--     partial failure completes the install instead of erroring out.
--   * A completeness assertion at the end: if any of the 6 tables, the key
--     unique indexes, or the triggers are missing, the script SIGNALs an error
--     instead of reporting success. "It ran" is not "it is correct."
--
-- Run with:   mysql --database=ledger < schema/00_install.sql
-- Re-running on a complete install is a no-op and still passes the assertion.
-- ---------------------------------------------------------------------------

SOURCE schema/01_tables.sql;
SOURCE schema/02_integrity_triggers.sql;
SOURCE schema/03_audit_triggers.sql;

-- --- completeness assertion ------------------------------------------------
-- Fails loudly on a partial install rather than silently approving it.
DELIMITER $$
DROP PROCEDURE IF EXISTS _assert_install_complete$$
CREATE PROCEDURE _assert_install_complete()
BEGIN
    DECLARE v_tables   INT;
    DECLARE v_uniques  INT;
    DECLARE v_triggers INT;

    SELECT COUNT(*) INTO v_tables
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN ('payments','seller_earnings','withdrawal_claims',
                         'source_allocations','allocation_evidence','audit_events');

    -- Count DISTINCT index names: a multi-column unique index produces one
    -- statistics row per column, so COUNT(*) would overcount.
    SELECT COUNT(DISTINCT index_name) INTO v_uniques
    FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND non_unique = 0
      AND index_name IN ('uq_allocation_earning','uq_earning_id_seller','uq_claim_id_seller');

    SELECT COUNT(*) INTO v_triggers
    FROM information_schema.triggers
    WHERE trigger_schema = DATABASE()
      AND trigger_name IN ('trg_audit_no_update','trg_audit_no_delete',
                           'trg_audit_hash_chain','trg_earning_no_overallocate_ins',
                           'trg_allocation_amount_matches_earning');

    IF v_tables <> 6 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'install incomplete: expected 6 ledger tables';
    END IF;
    IF v_uniques IS NULL OR v_uniques <> 3 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'install incomplete: missing a headline unique index';
    END IF;
    IF v_triggers <> 5 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'install incomplete: missing an integrity/audit trigger';
    END IF;

    SELECT 'install complete: 6 tables, unique guards and 5 triggers present' AS status;
END$$
DELIMITER ;

CALL _assert_install_complete();
DROP PROCEDURE _assert_install_complete;
