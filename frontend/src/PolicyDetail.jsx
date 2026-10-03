import React from 'react';
import { useParams } from 'react-router-dom';

/**
 * TODO(candidate)
 *  - policy + customer details, derived status, next due date
 *  - payment history, newest first, with amounts formatted as INR
 *  - a "Record Payment" form that:
 *      * cannot be submitted twice (double-click, Enter key, slow network)
 *      * sends an Idempotency-Key
 *      * shows the API's business-rule errors in language a branch clerk
 *        would understand, next to the field that caused them where possible
 *  - loading / error states
 */
export default function PolicyDetail() {
  const { id } = useParams();
  return (
    <div>
      <h1>Policy {id}</h1>
      <p className="todo">Not built yet.</p>
    </div>
  );
}
