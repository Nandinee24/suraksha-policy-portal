'use strict';

require('dotenv').config();
const express = require('express');
const cors = require('cors');

const { initPool, withConnection, closePool } = require('./db');
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

// TODO(candidate): a real error handler. Business-rule failures raised by the
// database should not all come back as 500.
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'INTERNAL', message: 'Something went wrong' });
});

const port = Number(process.env.PORT || 3001);

initPool()
  .then(() => {
    app.listen(port, () => console.log(`API listening on http://localhost:${port}`));
  })
  .catch((err) => {
    console.error('Could not start: database unreachable.', err.message);
    process.exit(1);
  });

process.on('SIGINT', async () => {
  await closePool();
  process.exit(0);
});
