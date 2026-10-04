import React from 'react';

// Every status has a word AND an icon shape, so it reads without colour
// (colour-blind staff, poor screens, printouts). Colour is only a bonus.
const STATUS = {
  PAID: { label: 'Paid up', icon: '✓', hint: 'Next premium is more than 30 days away' },
  DUE: { label: 'Due', icon: '●', hint: 'Premium due within the next 30 days' },
  IN_GRACE: { label: 'In grace', icon: '◐', hint: 'Due date has passed; still inside the grace period' },
  LAPSED: { label: 'Lapsed', icon: '✕', hint: 'Grace period ended without payment' },
  NOT_SERVICEABLE: { label: 'Check record', icon: '!', hint: 'Policy record is incomplete; payments cannot be taken' },
};

export const STATUS_OPTIONS = Object.entries(STATUS).map(([value, s]) => ({ value, label: s.label }));

export default function StatusBadge({ status }) {
  const s = STATUS[status] || { label: status || 'Unknown', icon: '?', hint: '' };
  return (
    <span className={`badge badge-${String(status).toLowerCase()}`} title={s.hint}>
      <span className="badge-icon" aria-hidden="true">{s.icon}</span>
      {s.label}
    </span>
  );
}
