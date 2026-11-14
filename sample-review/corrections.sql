-- ---------------------------------------------------------------------------
-- sample-review/corrections.sql
-- Recommended SQL corrections for findings F-01, F-02, F-03, F-04, F-05 and
-- F-06 in sample-review/REPORT.md.
--
-- All corrections are ADDITIVE (new triggers, one column collation change):
-- no table is dropped or rebuilt, and the script is re-runnable.
-- CI applies this file to a scratch database and proves each finding is now
-- rejected (.github/workflows/ci.yml, "Sample review corrections" step).
--
-- Run after the installer:
--   mysql ledger < schema/00_install.sql
--   mysql ledger < sample-review/corrections.sql
-- ---------------------------------------------------------------------------

DELIMITER $$

-- F-03 (part 1) ------------------------------------------------------------
-- The over-allocation guard only fired on INSERT. Guard UPDATE too, and freeze
-- the amount / payment / seller of an earning once it is allocated.
DROP TRIGGER IF EXISTS trg_earning_guard_upd$$
CREATE TRIGGER trg_earning_guard_upd
BEFORE UPDATE ON seller_earnings
FOR EACH ROW
BEGIN
    DECLARE v_total     BIGINT UNSIGNED;
    DECLARE v_others    BIGINT UNSIGNED;
    DECLARE v_allocated INT;

    IF NEW.amount_cents <> OLD.amount_cents
       OR NEW.payment_id <> OLD.payment_id
       OR NEW.seller_id  <> OLD.seller_id THEN

        SELECT COUNT(*) INTO v_allocated
        FROM source_allocations WHERE earning_id = OLD.id;
        IF v_allocated > 0 THEN
            SIGNAL SQLSTATE '45000'
              SET MESSAGE_TEXT = 'F-03: an allocated earning cannot change amount, payment or seller';
        END IF;

        SELECT amount_cents INTO v_total
        FROM payments WHERE id = NEW.payment_id FOR UPDATE;
        SELECT COALESCE(SUM(amount_cents), 0) INTO v_others
        FROM seller_earnings WHERE payment_id = NEW.payment_id AND id <> OLD.id;
        IF v_others + NEW.amount_cents > v_total THEN
            SIGNAL SQLSTATE '45000'
              SET MESSAGE_TEXT = 'F-03: update would over-allocate the payment';
        END IF;
    END IF;
END$$

-- F-03 (part 2) ------------------------------------------------------------
-- A payment amount must not be reduced below the earnings already assigned.
DROP TRIGGER IF EXISTS trg_payment_amount_guard$$
CREATE TRIGGER trg_payment_amount_guard
BEFORE UPDATE ON payments
FOR EACH ROW
BEGIN
    DECLARE v_earned BIGINT UNSIGNED;
    IF NEW.amount_cents < OLD.amount_cents THEN
        SELECT COALESCE(SUM(amount_cents), 0) INTO v_earned
        FROM seller_earnings WHERE payment_id = OLD.id;
        IF v_earned > NEW.amount_cents THEN
            SIGNAL SQLSTATE '45000'
              SET MESSAGE_TEXT = 'F-03: payment amount cannot drop below assigned earnings';
        END IF;
    END IF;
END$$

-- F-03 (part 3) ------------------------------------------------------------
-- Allocations are immutable: an UPDATE could otherwise re-point earning_id or
-- change amount_cents, bypassing both INSERT-time guards.
DROP TRIGGER IF EXISTS trg_allocation_no_update$$
CREATE TRIGGER trg_allocation_no_update
BEFORE UPDATE ON source_allocations
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'F-03: allocations are immutable; remove and re-add while the claim is open';
END$$

-- F-01 + F-02 --------------------------------------------------------------
-- An allocation may only consume an AVAILABLE earning, funded by a CAPTURED
-- payment, into an OPEN claim. The earning row is locked, so concurrent
-- allocations of the same earning serialize here (the loser is refused with a
-- clear reason instead of relying only on the duplicate-key backstop).
DROP TRIGGER IF EXISTS trg_allocation_preconditions$$
CREATE TRIGGER trg_allocation_preconditions
BEFORE INSERT ON source_allocations
FOR EACH ROW
FOLLOWS trg_allocation_amount_matches_earning
BEGIN
    DECLARE v_earning_status VARCHAR(16);
    DECLARE v_payment_status VARCHAR(32);
    DECLARE v_claim_status   VARCHAR(16);

    SELECT e.status, p.status INTO v_earning_status, v_payment_status
    FROM seller_earnings e
    JOIN payments p ON p.id = e.payment_id
    WHERE e.id = NEW.earning_id
    FOR UPDATE OF e;

    SELECT status INTO v_claim_status
    FROM withdrawal_claims WHERE id = NEW.claim_id;

    IF v_payment_status <> 'captured' THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'F-01: earning is funded by a payment that is not captured';
    END IF;
    IF v_earning_status <> 'available' THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'F-02: earning is not available for allocation';
    END IF;
    IF v_claim_status NOT IN ('draft', 'pending') THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'F-02: claim is not open for allocations';
    END IF;
END$$

-- F-02 + F-04 --------------------------------------------------------------
-- In the same statement as the allocation: mark the earning allocated and
-- maintain the claim total, so status and total_cents cannot drift from the
-- allocations that justify them.
DROP TRIGGER IF EXISTS trg_allocation_apply$$
CREATE TRIGGER trg_allocation_apply
AFTER INSERT ON source_allocations
FOR EACH ROW
BEGIN
    UPDATE seller_earnings
    SET status = 'allocated'
    WHERE id = NEW.earning_id;

    UPDATE withdrawal_claims
    SET total_cents = total_cents + NEW.amount_cents
    WHERE id = NEW.claim_id;
END$$

-- F-05 ---------------------------------------------------------------------
-- Allocations on an approved, paid or closed claim cannot be removed. While a
-- claim is still open, removal releases the earning and reduces the total.
DROP TRIGGER IF EXISTS trg_allocation_delete_guard$$
CREATE TRIGGER trg_allocation_delete_guard
BEFORE DELETE ON source_allocations
FOR EACH ROW
BEGIN
    DECLARE v_claim_status VARCHAR(16);
    SELECT status INTO v_claim_status
    FROM withdrawal_claims WHERE id = OLD.claim_id FOR UPDATE;
    IF v_claim_status NOT IN ('draft', 'pending') THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'F-05: allocations on an approved, paid or closed claim cannot be removed';
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_allocation_release$$
CREATE TRIGGER trg_allocation_release
AFTER DELETE ON source_allocations
FOR EACH ROW
BEGIN
    UPDATE seller_earnings
    SET status = 'available'
    WHERE id = OLD.earning_id AND status = 'allocated';

    UPDATE withdrawal_claims
    SET total_cents = total_cents - OLD.amount_cents
    WHERE id = OLD.claim_id;
END$$

DELIMITER ;

-- F-06 ---------------------------------------------------------------------
-- Provider references are case-sensitive identifiers. Under the default
-- utf8mb4_0900_ai_ci collation, 'pi_Abc' and 'pi_abc' collide on the UNIQUE
-- key (a false duplicate). Compare them byte-for-byte instead.
ALTER TABLE payments
    MODIFY external_ref VARCHAR(191) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;
