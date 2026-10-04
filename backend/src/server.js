'use strict';

require('dotenv').config();
const express = require('express');
const cors = require('cors');

const { initPool, withConnection, closePool } = require('./db');
const { toAppError } = require('./errors');
const policies = require('./routes/policies');

const app = express();
app.use(cors());
app.use(express.json());

app.get('/health', async (req, res) => {
  try {
    const r = await withConnection((c) => c.execute('SELECT 1 AS OK FROM DUAL'));
    res.json({ status: 'ok', db: r.rows[0] });
  } catch (err) {
    res.status(503).json({ status: 'down', error: err.message });
  }
});

app.use('/policies', policies);

app.use((req, res) => {
  res.status(404).json({ error: 'NOT_FOUND', message: `No route for ${req.method} ${req.path}` });
});

// Every error leaves as { error: CODE, message, details? }. Business-rule
// refusals from the database become 4xx (see errors.js); only unexpected
// failures are 500, and only those are logged with their stack.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const appErr = toAppError(err);
  if (appErr.status >= 500) console.error(err);
  res.status(appErr.status).json({
    error: appErr.code,
    message: appErr.message,
    ...(appErr.details ? { details: appErr.details } : {}),
  });
});

const port = Number(process.env.PORT || 3001);
let server;

initPool()
  .then(() => {
    server = app.listen(port, () => console.log(`API listening on http://localhost:${port}`));
  })
  .catch((err) => {
    console.error('Could not start: database unreachable.', err.message);
    process.exit(1);
  });

// Ctrl+C sends SIGINT; Docker and process managers send SIGTERM. Stop taking
// new requests, let running ones finish, then close the pool.
async function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  if (server) await new Promise((resolve) => server.close(resolve));
  await closePool();
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
