'use strict';

const oracledb = require('oracledb');

oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;
oracledb.fetchAsString = [oracledb.CLOB];

let pool = null;

async function initPool() {
  if (pool) return pool;
  pool = await oracledb.createPool({
    user: process.env.DB_USER || 'suraksha',
    password: process.env.DB_PASSWORD || 'suraksha',
    connectString: process.env.DB_CONNECT_STRING || 'localhost:1521/FREEPDB1',
    poolMin: Number(process.env.DB_POOL_MIN || 2),
    poolMax: Number(process.env.DB_POOL_MAX || 10),
    poolIncrement: 1,
    // Fail fast (503) instead of hanging for the 60 s default when every
    // connection is busy.
    queueTimeout: Number(process.env.DB_QUEUE_TIMEOUT_MS || 10000),
  });
  return pool;
}

/**
 * Borrows a pooled connection for fn and always gives it back, also when fn
 * throws. Closing a connection rolls back anything not committed, so a failed
 * request never leaves a transaction or a row lock behind.
 *
 * No separate transaction wrapper: every write is one RECORD_PAYMENT call,
 * committed with { autoCommit: true } on that execute.
 */
async function withConnection(fn) {
  const p = await initPool();
  const conn = await p.getConnection();
  try {
    return await fn(conn);
  } finally {
    try {
      await conn.close();
    } catch (closeErr) {
      // Don't let a failed release hide the error that fn threw.
      console.error('Failed to release DB connection', closeErr.message);
    }
  }
}

async function closePool() {
  if (pool) {
    await pool.close(10);
    pool = null;
  }
}

module.exports = { oracledb, initPool, withConnection, closePool };
