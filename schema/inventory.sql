-- ---------------------------------------------------------------------------
-- inventory.sql  —  read-only: which managed names are ours, missing, or
-- someone else's? Run before and after an install, and before any recovery.
--
--   owned    : exists and carries COMMENT='owner=ledger-registry;v=1'
--   missing  : not present (re-running 00_install.sql will create it)
--   FOREIGN  : the name is taken by an object this migration did NOT create.
--              Never modify or drop it. The installer refuses to run while
--              any FOREIGN row exists; resolve it with the owner first.
--
-- Run:  mysql ledger < schema/inventory.sql
-- ---------------------------------------------------------------------------
SELECT
    m.object_name,
    CASE
        WHEN t.table_name IS NULL THEN 'missing'
        WHEN t.table_type = 'BASE TABLE'
             AND t.table_comment LIKE 'owner=ledger-registry;%' THEN 'owned'
        ELSE 'FOREIGN - do not touch'
    END AS status,
    t.table_type,
    t.table_comment
FROM (
    SELECT 'payments'                AS object_name UNION ALL
    SELECT 'seller_earnings'                        UNION ALL
    SELECT 'withdrawal_claims'                      UNION ALL
    SELECT 'source_allocations'                     UNION ALL
    SELECT 'allocation_evidence'                    UNION ALL
    SELECT 'audit_events'                           UNION ALL
    SELECT 'ledger_audit_chain_head'                UNION ALL
    SELECT 'ledger_migration_log'
) AS m
LEFT JOIN information_schema.tables t
       ON t.table_schema = DATABASE()
      AND t.table_name   = m.object_name
ORDER BY m.object_name
