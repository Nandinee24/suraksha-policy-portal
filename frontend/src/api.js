// Vite proxies /api to the backend (see vite.config.js).
const BASE = '/api';

export async function getJson(path, options = {}) {
  const res = await fetch(BASE + path, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const err = new Error((body && body.message) || res.statusText);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

// TODO(candidate): you need an idempotency key per payment attempt.
// Where it is generated, and when it is regenerated, is a design decision -
// explain yours in NOTES.md.
