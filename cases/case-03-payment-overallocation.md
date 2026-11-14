# Case 03 — A payment funds more than it collected

**Risk:** High — the platform pays out more than it took in.

## The flaw
One buyer payment can fund several seller earnings (multiple lots on one
charge). If nothing checks the total, the sum of earnings against a payment can
exceed the payment amount — the platform distributes money it never received.

A single-row `CHECK` cannot catch this: it is a **cross-row** invariant
(sum over all earnings of a payment), so it needs a trigger or application
logic.

## The exploit
```sql
-- payment collected 10,000 cents
INSERT INTO seller_earnings (payment_id, seller_id, amount_cents) VALUES (P, 1, 6000);
INSERT INTO seller_earnings (payment_id, seller_id, amount_cents) VALUES (P, 2, 5000);
-- 6000 + 5000 = 11,000 > 10,000 collected
```

## The fix
A `BEFORE INSERT` trigger that locks the payment row and rejects any earning
that would push the running total over the collected amount:

```sql
SELECT amount_cents INTO v_payment_total FROM payments WHERE id = NEW.payment_id FOR UPDATE;
SELECT COALESCE(SUM(amount_cents),0) INTO v_already FROM seller_earnings WHERE payment_id = NEW.payment_id;
IF (v_already + NEW.amount_cents) > v_payment_total THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'over-allocation: exceeds payment amount';
END IF;
```

The `FOR UPDATE` on the payment row serializes concurrent earning inserts so
two of them cannot both read the old total and both pass.

## The test
`tests/test_integrity.py::test_payment_overallocation_is_rejected`
