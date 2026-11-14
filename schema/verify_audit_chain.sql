-- ---------------------------------------------------------------------------
-- verify_audit_chain.sql  —  read-only tamper check for audit_events.
--
-- Returns one row per problem; an EMPTY result means the chain is intact.
--   hash_mismatch  : a row's stored row_hash no longer matches its contents
--                    (the row was altered after it was written)
--   broken_link    : a row points at a predecessor hash that no longer exists
--                    (an earlier row was removed or altered)
--   extra_genesis  : more than one row claims to start the chain
--   forked_link    : two rows claim the same predecessor (should be impossible
--                    while UNIQUE (prev_hash) exists; reported if it is dropped)
--
-- Run:  mysql ledger < schema/verify_audit_chain.sql
-- ---------------------------------------------------------------------------
SELECT a.id, 'hash_mismatch' AS problem
FROM audit_events a
WHERE a.row_hash <> SHA2(
        CONCAT_WS('|',
            COALESCE(a.prev_hash, ''),
            a.event_type,
            a.entity_type,
            COALESCE(a.entity_id, ''),
            COALESCE(a.seller_id, ''),
            a.actor,
            COALESCE(CAST(CAST(a.payload AS JSON) AS CHAR), '')
        ), 256)
UNION ALL
SELECT a.id, 'broken_link'
FROM audit_events a
LEFT JOIN audit_events p ON p.row_hash = a.prev_hash
WHERE a.prev_hash IS NOT NULL AND p.id IS NULL
UNION ALL
SELECT a.id, 'extra_genesis'
FROM audit_events a
WHERE a.prev_hash IS NULL
  AND a.id <> (SELECT MIN(g.id) FROM audit_events g WHERE g.prev_hash IS NULL)
UNION ALL
SELECT a.id, 'forked_link'
FROM audit_events a
JOIN audit_events b ON b.prev_hash = a.prev_hash AND b.id < a.id
WHERE a.prev_hash IS NOT NULL
