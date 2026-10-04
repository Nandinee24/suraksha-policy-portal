import React, { useRef, useState } from 'react';
import { request, newIdempotencyKey } from './api.js';
import { formatINR } from './format.js';

const CHANNELS = [
  { value: 'BRANCH', label: 'Cash / cheque at branch' },
  { value: 'ONLINE', label: 'Online' },
  { value: 'AGENT', label: 'Agent' },
  { value: 'AUTO-DEBIT', label: 'Auto-debit' },
];

/** What the clerk reads when a payment is refused, chosen by error code. */
function clerkMessage(err) {
  if (err.status === 0 || err.status >= 500) {
    return 'Could not reach the server, so this payment is NOT confirmed. Press "Record payment" again: the customer will not be charged twice.';
  }
  switch (err.code) {
    case 'POLICY_BUSY':
      return 'Another counter is recording a payment for this policy right now. Wait a few seconds, then press "Record payment" again.';
    case 'IDEMPOTENCY_KEY_REUSED':
      return 'This form was already used for a different payment, so it has been reset. Press "Record payment" again.';
    default:
      // AMOUNT_MISMATCH, REVIVAL_WINDOW_EXPIRED, NOT_YET_DUE, ... come from the
      // database already written for a clerk (amounts in rupees, dates).
      return err.message || 'The payment could not be recorded.';
  }
}

/**
 * Record Payment form. Cannot be submitted twice:
 *  - inFlight ref: set synchronously, so a double-click's second event is
 *    ignored even before React re-renders the disabled button;
 *  - the button and fields are disabled while a request is running;
 *  - Enter submits the same form, so the same guard applies;
 *  - the Idempotency-Key makes the server answer a repeat with the first
 *    result instead of a second payment (slow network, retries).
 *
 * The parent remounts this form (key = due date) after a payment or a refresh.
 */
export default function PaymentForm({ policy, onRecorded, onStale }) {
  const [amount, setAmount] = useState('');
  const [channel, setChannel] = useState('BRANCH');
  const [submitting, setSubmitting] = useState(false);
  const [amountError, setAmountError] = useState(null);
  const [formError, setFormError] = useState(null);

  const inFlight = useRef(false);
  // New key = new payment attempt. Kept when a request fails on the network,
  // so pressing again is a safe retry of the SAME attempt.
  const idemKey = useRef(newIdempotencyKey());

  function changeAmount(value) {
    setAmount(value);
    setAmountError(null);
    setFormError(null);
    idemKey.current = newIdempotencyKey(); // different amount = different request
  }

  async function submit(e) {
    e.preventDefault();
    if (inFlight.current) return;

    setAmountError(null);
    setFormError(null);
    const text = amount.trim().replace(/,/g, '');
    if (!/^\d{1,10}(\.\d{1,2})?$/.test(text) || Number(text) <= 0) {
      setAmountError('Enter the amount in rupees, for example 12500 or 12500.50.');
      return;
    }

    inFlight.current = true;
    setSubmitting(true);
    try {
      const { data } = await request(`/policies/${policy.id}/payments`, {
        method: 'POST',
        headers: { 'Idempotency-Key': idemKey.current },
        body: { amount: Number(text), channel, expectedDueDate: policy.nextDueDate },
      });
      onRecorded(data);
    } catch (err) {
      if (err.code === 'STALE_DUE_DATE') {
        onStale(clerkMessage(err));
        return;
      }
      if (err.code === 'IDEMPOTENCY_KEY_REUSED') idemKey.current = newIdempotencyKey();
      if (err.code === 'AMOUNT_MISMATCH' || (err.details && err.details.field === 'amount')) {
        setAmountError(clerkMessage(err));
      } else {
        setFormError(clerkMessage(err));
      }
    } finally {
      inFlight.current = false;
      setSubmitting(false);
    }
  }

  return (
    <form className="pay-form" onSubmit={submit} noValidate>
      <h2>Record payment</h2>
      <fieldset disabled={submitting}>
        <div className="field">
          <label htmlFor="pay-amount">Amount received (₹)</label>
          <div className="amount-row">
            <input
              id="pay-amount"
              inputMode="decimal"
              autoComplete="off"
              value={amount}
              onChange={(e) => changeAmount(e.target.value)}
              placeholder={String(policy.amountDue)}
              aria-invalid={Boolean(amountError)}
              aria-describedby="pay-amount-help pay-amount-error"
            />
            <button type="button" className="button-secondary" onClick={() => changeAmount(String(policy.amountDue))}>
              Use {formatINR(policy.amountDue)}
            </button>
          </div>
          <p id="pay-amount-help" className="muted small">
            Must be exactly {formatINR(policy.amountDue)}. Part payments and extra amounts are not accepted.
          </p>
          {amountError && <p id="pay-amount-error" className="field-error" role="alert">{amountError}</p>}
        </div>

        <div className="field">
          <label htmlFor="pay-channel">Paid by</label>
          <select id="pay-channel" value={channel} onChange={(e) => { setChannel(e.target.value); idemKey.current = newIdempotencyKey(); }}>
            {CHANNELS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
          </select>
        </div>

        {formError && <p className="form-error" role="alert">{formError}</p>}

        <button type="submit" className="button-primary">
          {submitting ? 'Recording…' : 'Record payment'}
        </button>
      </fieldset>
    </form>
  );
}
