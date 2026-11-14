-- ---------------------------------------------------------------------------
-- 00_install.sql  —  ordered, re-runnable, ownership-aware installer.
--
-- WHY THIS FILE EXISTS
-- In MySQL every DDL statement implicitly commits and is NOT transactional:
-- you cannot wrap CREATE TABLE ... in a transaction and ROLLBACK the lot if
-- statement 4 of 6 fails. An interrupted install leaves a PARTIAL registry.
-- (Review scope item 5.)
--
-- THE HARDER QUESTION: whose objects are these?
-- After an interruption, recovery must distinguish objects THIS migration
-- created from objects that already existed and must never be modified or
-- dropped. Name matching alone cannot do that, and CREATE TABLE IF NOT EXISTS
-- silently skips a same-named table with a DIFFERENT structure. So:
--
--   1. OWNERSHIP MARKER  Every object this migration creates carries
--      COMMENT='owner=ledger-registry;v=1'. Ownership is a recorded fact,
--      not a guess from the name.
--   2. PREFLIGHT  Before anything is created, refuse to run if any managed
--      name is already taken by an object WITHOUT the marker (or by a trigger
--      on a table this migration does not own). Nothing is touched.
--   3. MIGRATION LOG  ledger_migration_log records each completed step, so
--      after an interruption you can see exactly how far the install got.
--   4. DEFINITION CHECKS  The final assertion verifies structure (key columns,
--      foreign keys, money column types, triggers, chain head), not just that
--      names exist. "It ran" is not allowed to mean "it is correct."
--   5. NO DROPS  The installer never drops a table. Recovery = re-run; the
--      IF NOT EXISTS guards create only what is missing, and only on names the
--      preflight has proven are ours or free.
--
-- Run from the repo root (SOURCE paths are relative to the working dir):
--     mysql --database=ledger < schema/00_install.sql
-- Inspect ownership at any time with schema/inventory.sql.
-- ---------------------------------------------------------------------------

-- 1. PREFLIGHT ---------------------------------------------------------------
DELIMITER $$
DROP PROCEDURE IF EXISTS ledger_preflight$$
CREATE PROCEDURE ledger_preflight()
BEGIN
    DECLARE v_foreign_tables   INT;
    DECLARE v_foreign_triggers INT;

    -- A managed name held by something we did not create (no marker, or a
    -- view instead of a table) means: stop, touch nothing.
    SELECT COUNT(*) INTO v_foreign_tables
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN ('payments','seller_earnings','withdrawal_claims',
                         'source_allocations','allocation_evidence','audit_events',
                         'ledger_audit_chain_head','ledger_migration_log')
      AND (table_type <> 'BASE TABLE'
           OR table_comment NOT LIKE 'owner=ledger-registry;%');

    IF v_foreign_tables > 0 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'preflight: a managed name is held by an object not owned by this migration; nothing was changed. Run schema/inventory.sql';
    END IF;

    -- DROP TRIGGER IF EXISTS would otherwise remove a same-named trigger that
    -- belongs to someone else's table.
    SELECT COUNT(*) INTO v_foreign_triggers
    FROM information_schema.triggers
    WHERE trigger_schema = DATABASE()
      AND trigger_name IN ('trg_audit_no_update','trg_audit_no_delete',
                           'trg_audit_hash_chain','trg_earning_no_overallocate_ins',
                           'trg_allocation_amount_matches_earning')
      AND event_object_table NOT IN ('audit_events','seller_earnings','source_allocations');

    IF v_foreign_triggers > 0 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'preflight: a managed trigger name is used on a table this migration does not own; nothing was changed';
    END IF;
END$$
DELIMITER ;

CALL ledger_preflight();
DROP PROCEDURE ledger_preflight;

-- 2. MIGRATION LOG -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS ledger_migration_log (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    version     VARCHAR(64)     NOT NULL,
    step        VARCHAR(64)     NOT NULL,
    applied_at  DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_migration_step (version, step)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- 3. ORDERED INSTALL (parents before children), each step logged -------------
SOURCE schema/01_tables.sql;
INSERT IGNORE INTO ledger_migration_log (version, step) VALUES ('ledger-v1', '01_tables');

SOURCE schema/02_integrity_triggers.sql;
INSERT IGNORE INTO ledger_migration_log (version, step) VALUES ('ledger-v1', '02_integrity_triggers');

SOURCE schema/03_audit_triggers.sql;
INSERT IGNORE INTO ledger_migration_log (version, step) VALUES ('ledger-v1', '03_audit_triggers');

-- 4. DEFINITION-LEVEL COMPLETENESS ASSERTION ---------------------------------
DELIMITER $$
DROP PROCEDURE IF EXISTS ledger_assert_install_complete$$
CREATE PROCEDURE ledger_assert_install_complete()
BEGIN
    DECLARE v_owned      INT;
    DECLARE v_alloc_uq   INT;
    DECLARE v_alloc_uq_n INT;
    DECLARE v_owner_uqs  INT;
    DECLARE v_prev_uq    INT;
    DECLARE v_fks        INT;
    DECLARE v_fk_cols    INT;
    DECLARE v_money      INT;
    DECLARE v_triggers   INT;
    DECLARE v_head       INT;

    -- All eight managed tables exist AND carry the ownership marker.
    SELECT COUNT(*) INTO v_owned
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_type = 'BASE TABLE'
      AND table_comment LIKE 'owner=ledger-registry;%'
      AND table_name IN ('payments','seller_earnings','withdrawal_claims',
                         'source_allocations','allocation_evidence','audit_events',
                         'ledger_audit_chain_head','ledger_migration_log');

    -- Headline guarantee: uq_allocation_earning is UNIQUE on exactly earning_id.
    SELECT COUNT(*) INTO v_alloc_uq
    FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'source_allocations'
      AND index_name = 'uq_allocation_earning' AND non_unique = 0
      AND column_name = 'earning_id';
    SELECT COUNT(*) INTO v_alloc_uq_n
    FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'source_allocations'
      AND index_name = 'uq_allocation_earning';

    -- Composite owner keys exist on the right tables with the right columns.
    SELECT COUNT(*) INTO v_owner_uqs
    FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND non_unique = 0
      AND ((table_name = 'seller_earnings'   AND index_name = 'uq_earning_id_seller')
        OR (table_name = 'withdrawal_claims' AND index_name = 'uq_claim_id_seller'))
      AND column_name IN ('id', 'seller_id');

    -- Audit fork backstop.
    SELECT COUNT(*) INTO v_prev_uq
    FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'audit_events'
      AND index_name = 'uq_audit_prev_hash' AND non_unique = 0
      AND column_name = 'prev_hash';

    -- Ownership FKs point at the right parents ...
    SELECT COUNT(*) INTO v_fks
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND ((constraint_name = 'fk_allocation_earning_owned' AND referenced_table_name = 'seller_earnings')
        OR (constraint_name = 'fk_allocation_claim_owned'   AND referenced_table_name = 'withdrawal_claims'));
    -- ... and each binds two columns, one of them seller_id.
    SELECT COUNT(*) INTO v_fk_cols
    FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = 'source_allocations'
      AND constraint_name IN ('fk_allocation_earning_owned','fk_allocation_claim_owned')
      AND column_name IN ('earning_id','claim_id','seller_id');

    -- Every money column is integer cents (BIGINT UNSIGNED), never float/decimal.
    SELECT COUNT(*) INTO v_money
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND column_type LIKE 'bigint%unsigned'
      AND ((table_name IN ('payments','seller_earnings','source_allocations') AND column_name = 'amount_cents')
        OR (table_name = 'withdrawal_claims' AND column_name = 'total_cents'));

    SELECT COUNT(*) INTO v_triggers
    FROM information_schema.triggers
    WHERE trigger_schema = DATABASE()
      AND ((trigger_name IN ('trg_audit_no_update','trg_audit_no_delete','trg_audit_hash_chain')
            AND event_object_table = 'audit_events')
        OR (trigger_name = 'trg_earning_no_overallocate_ins' AND event_object_table = 'seller_earnings')
        OR (trigger_name = 'trg_allocation_amount_matches_earning' AND event_object_table = 'source_allocations'));

    SELECT COUNT(*) INTO v_head FROM ledger_audit_chain_head WHERE id = 1;

    IF v_owned <> 8 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incomplete: expected 8 owned ledger tables';
    END IF;
    IF v_alloc_uq <> 1 OR v_alloc_uq_n <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incorrect: uq_allocation_earning must be UNIQUE on exactly earning_id';
    END IF;
    IF v_owner_uqs <> 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incorrect: composite (id, seller_id) owner keys missing or wrong';
    END IF;
    IF v_prev_uq <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incorrect: audit fork backstop uq_audit_prev_hash missing';
    END IF;
    IF v_fks <> 2 OR v_fk_cols <> 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incorrect: seller-ownership foreign keys missing or wrong';
    END IF;
    IF v_money <> 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incorrect: a money column is not BIGINT UNSIGNED integer cents';
    END IF;
    IF v_triggers <> 5 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incomplete: an integrity/audit trigger is missing or on the wrong table';
    END IF;
    IF v_head <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'install incomplete: audit chain head row missing';
    END IF;

    SELECT 'install complete: 8 owned tables, definitions verified, 5 triggers, chain head present' AS status;
END$$
DELIMITER ;

CALL ledger_assert_install_complete();
DROP PROCEDURE ledger_assert_install_complete;
INSERT IGNORE INTO ledger_migration_log (version, step) VALUES ('ledger-v1', 'verified');
