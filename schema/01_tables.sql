-- ---------------------------------------------------------------------------
-- 01_tables.sql
-- Six-table InnoDB ledger for seller earnings -> withdrawal payouts.
--
-- Design rules enforced here:
--   * All money is stored as BIGINT UNSIGNED integer cents. No FLOAT/DECIMAL
--     rounding surprises, no negative amounts.
--   * InnoDB everywhere, utf8mb4, so foreign keys and row locks actually work.
--   * Every table that another table must bind to by owner exposes a
--     UNIQUE (id, seller_id) key, so a *composite* foreign key can force the
--     child row to belong to the same seller as its parent.
--   * CREATE TABLE IF NOT EXISTS so a re-run after a half-finished install is
--     safe (see cases/case-05-partial-ddl-recovery.md: MySQL DDL auto-commits
--     and is not transactional, so partial installs are a real risk).
--   * Every table carries the ownership marker COMMENT='owner=ledger-registry;v=1'.
--     The installer's preflight refuses to proceed if a table with one of these
--     names already exists WITHOUT the marker, so it can never adopt, alter or
--     drop an object it did not create.
--
-- Requires MySQL 8.0.16+ (CHECK constraints are enforced from that version;
-- on older versions they parse but are ignored, which this lab treats as a
-- finding, not a pass).
-- ---------------------------------------------------------------------------

-- 1. payments -------------------------------------------------------------
-- A buyer payment. One payment can fund many seller earnings (multiple
-- auction lots settled by a single charge).
CREATE TABLE IF NOT EXISTS payments (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    external_ref   VARCHAR(191)    NOT NULL,              -- e.g. Stripe PaymentIntent id
    amount_cents   BIGINT UNSIGNED NOT NULL,
    currency       CHAR(3)         NOT NULL DEFAULT 'USD',
    status         ENUM('pending','captured','refunded','partially_refunded')
                                   NOT NULL DEFAULT 'pending',
    created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_payments_external_ref (external_ref),
    CONSTRAINT ck_payments_amount_positive CHECK (amount_cents > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- 2. seller_earnings ------------------------------------------------------
-- An amount owed to one seller, funded by one payment. This is the unit that
-- gets consumed by a withdrawal. status is the lifecycle guard used together
-- with SELECT ... FOR UPDATE to serialize concurrent withdrawals.
CREATE TABLE IF NOT EXISTS seller_earnings (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    payment_id     BIGINT UNSIGNED NOT NULL,
    seller_id      BIGINT UNSIGNED NOT NULL,
    amount_cents   BIGINT UNSIGNED NOT NULL,
    status         ENUM('available','allocated','paid','reversed')
                                   NOT NULL DEFAULT 'available',
    created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- Composite key so children can bind (earning_id, seller_id) and prove
    -- the earning really belongs to the seller they claim.
    UNIQUE KEY uq_earning_id_seller (id, seller_id),
    KEY idx_earning_payment (payment_id),
    KEY idx_earning_seller_status (seller_id, status),
    CONSTRAINT fk_earning_payment
        FOREIGN KEY (payment_id) REFERENCES payments (id),
    CONSTRAINT ck_earning_amount_positive CHECK (amount_cents > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- 3. withdrawal_claims ----------------------------------------------------
-- A seller's request to be paid out a set of earnings.
CREATE TABLE IF NOT EXISTS withdrawal_claims (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    seller_id      BIGINT UNSIGNED NOT NULL,
    status         ENUM('draft','pending','approved','paid','rejected','cancelled')
                                   NOT NULL DEFAULT 'draft',
    total_cents    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- Composite key so an allocation can bind (claim_id, seller_id).
    UNIQUE KEY uq_claim_id_seller (id, seller_id),
    KEY idx_claim_seller_status (seller_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- 4. source_allocations ---------------------------------------------------
-- The join that ties ONE earning to ONE withdrawal claim. This table is where
-- the two headline guarantees live:
--   * uq_allocation_earning: an earning can appear in at most one allocation,
--     so the same earning can never be paid out twice (double-allocation).
--   * the two composite FKs: the earning and the claim must belong to the
--     SAME seller, so earnings can never be attached to another seller's
--     claim (cross-seller allocation).
CREATE TABLE IF NOT EXISTS source_allocations (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    claim_id       BIGINT UNSIGNED NOT NULL,
    earning_id     BIGINT UNSIGNED NOT NULL,
    seller_id      BIGINT UNSIGNED NOT NULL,   -- must equal both parents' seller_id
    amount_cents   BIGINT UNSIGNED NOT NULL,
    created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- HEADLINE GUARANTEE 1: no earning consumed twice.
    UNIQUE KEY uq_allocation_earning (earning_id),
    KEY idx_allocation_claim (claim_id),
    -- HEADLINE GUARANTEE 2: earning and claim must be the same seller's.
    CONSTRAINT fk_allocation_earning_owned
        FOREIGN KEY (earning_id, seller_id)
        REFERENCES seller_earnings (id, seller_id),
    CONSTRAINT fk_allocation_claim_owned
        FOREIGN KEY (claim_id, seller_id)
        REFERENCES withdrawal_claims (id, seller_id),
    CONSTRAINT ck_allocation_amount_positive CHECK (amount_cents > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- 5. allocation_evidence --------------------------------------------------
-- Supporting documents / references for an allocation (payout proof, invoice).
CREATE TABLE IF NOT EXISTS allocation_evidence (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    allocation_id  BIGINT UNSIGNED NOT NULL,
    evidence_type  VARCHAR(64)     NOT NULL,
    evidence_uri   VARCHAR(1024)   NOT NULL,
    content_sha256 CHAR(64)        NULL,
    created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_evidence_allocation (allocation_id),
    CONSTRAINT fk_evidence_allocation
        FOREIGN KEY (allocation_id) REFERENCES source_allocations (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';

-- 6. audit_events ---------------------------------------------------------
-- Append-only audit log. Immutability is enforced by triggers in
-- 03_audit_triggers.sql; row_hash/prev_hash form a tamper-evident chain.
CREATE TABLE IF NOT EXISTS audit_events (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    event_type     VARCHAR(64)     NOT NULL,
    entity_type    VARCHAR(64)     NOT NULL,
    entity_id      BIGINT UNSIGNED NULL,
    seller_id      BIGINT UNSIGNED NULL,
    actor          VARCHAR(191)    NOT NULL DEFAULT 'system',
    payload        JSON            NULL,
    prev_hash      CHAR(64)        NULL,
    row_hash       CHAR(64)        NOT NULL,
    created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- No two rows may claim the same predecessor: a forked chain fails on
    -- insert instead of silently branching (backstop for the chain-head lock).
    UNIQUE KEY uq_audit_prev_hash (prev_hash),
    KEY idx_audit_entity (entity_type, entity_id),
    KEY idx_audit_seller (seller_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='owner=ledger-registry;v=1';
