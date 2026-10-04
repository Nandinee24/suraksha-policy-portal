const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' });

/** 125000 -> "₹1,25,000.00" (Indian digit grouping). */
export function formatINR(value) {
  return value === null || value === undefined ? '—' : inr.format(value);
}

/**
 * "2026-10-04" -> "04 Oct 2026". Split as text on purpose: new Date("2026-10-04")
 * is read as UTC midnight and can show the previous day in some timezones.
 */
export function formatDate(isoDate) {
  if (!isoDate) return '—';
  const [y, m, d] = isoDate.slice(0, 10).split('-');
  return `${d} ${MONTHS[Number(m) - 1]} ${y}`;
}

/** "2026-10-04T14:05:00+05:30" (sent in IST by the API) -> "04 Oct 2026, 2:05 pm IST". */
export function formatDateTime(isoDateTime) {
  if (!isoDateTime) return '—';
  const [date, time] = isoDateTime.split('T');
  const [hh, mm] = time.split(':');
  const hour = Number(hh);
  return `${formatDate(date)}, ${hour % 12 || 12}:${mm} ${hour >= 12 ? 'pm' : 'am'} IST`;
}

const MODE_LABELS = { Y: 'Yearly', H: 'Half-yearly', Q: 'Quarterly', M: 'Monthly' };

export function modeLabel(code) {
  return MODE_LABELS[code] || 'Unknown';
}
