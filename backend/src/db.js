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
  });
  return pool;
}

/**
 * TODO(candidate): this helper is deliberately thin.
 * Decide for yourself how connections are acquired and released, how errors
 * propagate, and whether you want an explicit transaction wrapper as well.
 */
async function withConnection(fn) {
  const p = await initPool();
  const conn = await p.getConnection();
  try {
    return await fn(conn);
  } finally {
    await conn.close();
  }
}

async function closePool() {
  if (pool) {
    await pool.close(10);
    pool = null;
  }
}

module.exports = { oracledb, initPool, withConnection, closePool };
