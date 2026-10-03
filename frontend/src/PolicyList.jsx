import React from 'react';

/**
 * TODO(candidate)
 *  - list policies from GET /policies
 *  - status filter (PAID / DUE / IN_GRACE / LAPSED)
 *  - search by policy number or customer name
 *  - server-side pagination (do not fetch everything and slice it in the browser)
 *  - loading / empty / error states
 *  - the status must be readable at a glance, and not by colour alone
 */
export default function PolicyList() {
  return (
    <div>
      <h1>Policies</h1>
      <p className="todo">Not built yet.</p>
    </div>
  );
}
