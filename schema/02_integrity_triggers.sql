-- ---------------------------------------------------------------------------
-- 02_integrity_triggers.sql
-- Cross-row financial invariants that a single-row CHECK constraint cannot
-- express. These are the "what the database can enforce vs what needs the
-- application" boundary (review scope item 6).
--
-- Enforced here at the DB level:
--   A. A payment cannot be over-allocated: the sum of its seller_earnings
--      must never exceed the payment amount.
--   B. An allocation's amount must exactly equal the earning it consumes
--      (this lab models whole-earning consumption; partial payout of a single
--      earning is deliberately out of scope and documented as such).
--
-- Still left to the application layer (documented, not silently assumed):
--   * Keeping withdrawal_claims.total_cents in step with the sum of its
--     allocations (a derived cache; see README "Database vs application").
--   * Refund / reversal accounting once money has left the platform.
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_earning_no_overallocate_ins;
DROP TRIGGER IF EXISTS trg_allocation_amount_matches_earning;

DELIMITER $$

-- A. Prevent a payment from being over-allocated across its earnings.
CREATE TRIGGER trg_earning_no_overallocate_ins
BEFORE INSERT ON seller_earnings
FOR EACH ROW
BEGIN
    DECLARE v_payment_total   BIGINT UNSIGNED;
    DECLARE v_already_earned  BIGINT UNSIGNED;

    SELECT amount_cents INTO v_payment_total
    FROM payments WHERE id = NEW.payment_id FOR UPDATE;

    SELECT COALESCE(SUM(amount_cents), 0) INTO v_already_earned
    FROM seller_earnings WHERE payment_id = NEW.payment_id;

    IF (v_already_earned + NEW.amount_cents) > v_payment_total THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'over-allocation: seller_earnings would exceed payment amount';
    END IF;
END$$

-- B. An allocation must consume the earning in full. Mismatched amounts are a
-- classic place for a few cents to leak, so reject them at write time.
CREATE TRIGGER trg_allocation_amount_matches_earning
BEFORE INSERT ON source_allocations
FOR EACH ROW
BEGIN
    DECLARE v_earning_amount BIGINT UNSIGNED;

    SELECT amount_cents INTO v_earning_amount
    FROM seller_earnings WHERE id = NEW.earning_id;

    IF v_earning_amount IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'allocation references a non-existent earning';
    END IF;

    IF NEW.amount_cents <> v_earning_amount THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'allocation amount must equal the earning amount (no partial consumption)';
    END IF;
END$$

DELIMITER ;
