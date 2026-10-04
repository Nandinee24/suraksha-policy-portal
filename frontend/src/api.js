// Vite proxies /api to the backend (see vite.config.js).
const BASE = '/api';

/** Error from the API, carrying its machine-readable code ("AMOUNT_MISMATCH"). */
export class ApiError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'ApiError';
    this.status = status; // 0 = the server could not be reached
    this.code = code;
    this.details = details;
  }
}

export async function request(path, { method = 'GET', body, headers, signal } = {}) {
  let res;
  try {
    res = await fetch(BASE + path, {
      method,
      signal,
      // Spread the caller's headers INTO ours. (The starter spread `options`
      // last, so passing an Idempotency-Key header wiped out Content-Type and
      // the server received an empty body.)
      headers: { 'Content-Type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (err) {
    if (err.name === 'AbortError') throw err;
    throw new ApiError(0, 'NETWORK_ERROR', 'Could not reach the server.');
  }

  // A proxy error page (backend down) is not JSON: don't crash on it.
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }

  if (!res.ok) {
    throw new ApiError(
      res.status,
      (data && data.error) || `HTTP_${res.status}`,
      (data && data.message) || res.statusText,
      data && data.details,
    );
  }
  return { data, status: res.status, headers: res.headers };
}

/**
 * One key per payment ATTEMPT. The form keeps the same key when it retries
 * after a network error (so the server replays instead of charging again) and
 * makes a new one after a success or when the amount changes.
 */
export function newIdempotencyKey() {
  return crypto.randomUUID();
}

/** Text for the general error box on list/detail screens. */
export function loadErrorMessage(err) {
  if (err.status === 0 || err.status >= 500) {
    return 'Could not reach the server. Check your connection and try again.';
  }
  return err.message || 'Something went wrong.';
}
