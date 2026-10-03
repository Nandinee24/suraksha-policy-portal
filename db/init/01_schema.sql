--------------------------------------------------------------------------------
-- Suraksha Life Insurance - Policy Servicing Mini-Portal
-- 01_schema.sql   (PARTIAL SCHEMA - you are expected to finish this)
--
-- This is the schema as it was lifted out of the legacy system. It loads, and
-- the application can technically read from it, but it is NOT production ready.
--
-- Part of your task is to decide what is missing or wrong here and to fix it
-- with your OWN migration script (see db/migrations/README.md). Do not edit
-- this file - we want to see your migration, not your edit history on ours.
--------------------------------------------------------------------------------

-- The container runs this file as SYS against the root container, so switch
-- into the pluggable database that actually holds the application schema.
ALTER SESSION SET CONTAINER = FREEPDB1;
SET DEFINE OFF;

-- Defensive: the image normally creates the app user before this script runs.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM DBA_USERS WHERE USERNAME = 'SURAKSHA';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER SURAKSHA IDENTIFIED BY suraksha';
    EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO SURAKSHA';
    EXECUTE IMMEDIATE 'ALTER USER SURAKSHA QUOTA UNLIMITED ON USERS';
  END IF;
END;
/

-- RESOURCE does not include CREATE VIEW, and you will need it.
GRANT CREATE VIEW, CREATE MATERIALIZED VIEW, CREATE SYNONYM TO SURAKSHA;
ALTER USER SURAKSHA QUOTA UNLIMITED ON USERS;

ALTER SESSION SET CURRENT_SCHEMA = SURAKSHA;

--------------------------------------------------------------------------------
-- CUSTOMERS
--------------------------------------------------------------------------------
CREATE TABLE SURAKSHA.CUSTOMERS (
  CUSTOMER_ID    NUMBER          NOT NULL,
  FULL_NAME      VARCHAR2(120),
  PAN            VARCHAR2(20),
  EMAIL          VARCHAR2(120),
  MOBILE         VARCHAR2(20),
  CITY           VARCHAR2(60),
  CREATED_AT     TIMESTAMP       DEFAULT SYSTIMESTAMP,
  CONSTRAINT PK_CUSTOMERS PRIMARY KEY (CUSTOMER_ID)
);

--------------------------------------------------------------------------------
-- POLICIES
--
-- PREMIUM_MODE and PREMIUM_AMOUNT arrive from the legacy export as free text.
-- NEXT_DUE_DATE is the date the next unpaid instalment is due.
-- FIRST_UNPAID_DUE_DATE is the due date of the OLDEST instalment still unpaid
-- (it is what the 2-year revival window is measured from). It is NULL when the
-- policy has nothing outstanding.
--------------------------------------------------------------------------------
CREATE TABLE SURAKSHA.POLICIES (
  POLICY_ID              NUMBER        NOT NULL,
  POLICY_NO              VARCHAR2(30),
  CUSTOMER_ID            NUMBER,
  PLAN_NAME              VARCHAR2(80),
  PREMIUM_MODE           VARCHAR2(20),
  PREMIUM_AMOUNT         VARCHAR2(30),
  SUM_ASSURED            NUMBER,
  COMMENCEMENT_DATE      DATE,
  NEXT_DUE_DATE          DATE,
  FIRST_UNPAID_DUE_DATE  DATE,
  LEGACY_STATUS          VARCHAR2(20),
  CREATED_AT             TIMESTAMP     DEFAULT SYSTIMESTAMP,
  CONSTRAINT PK_POLICIES PRIMARY KEY (POLICY_ID)
);

--------------------------------------------------------------------------------
-- PAYMENTS
--
-- PAID_AT is stored in UTC. The business runs in IST (UTC+05:30).
--------------------------------------------------------------------------------
CREATE TABLE SURAKSHA.PAYMENTS (
  PAYMENT_ID       NUMBER        NOT NULL,
  POLICY_ID        NUMBER,
  AMOUNT           NUMBER(12,2),
  PAID_AT          TIMESTAMP,
  IDEMPOTENCY_KEY  VARCHAR2(64),
  COVERS_DUE_DATE  DATE,
  CHANNEL          VARCHAR2(20),
  CREATED_AT       TIMESTAMP     DEFAULT SYSTIMESTAMP,
  CONSTRAINT PK_PAYMENTS PRIMARY KEY (PAYMENT_ID)
);

CREATE SEQUENCE SURAKSHA.SEQ_PAYMENT_ID START WITH 900000 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE SURAKSHA.SEQ_CUSTOMER_ID START WITH 900000 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE SURAKSHA.SEQ_POLICY_ID START WITH 900000 INCREMENT BY 1 NOCACHE;

--------------------------------------------------------------------------------
-- RECORD_PAYMENT
--
-- Stub only. Implementing this is part of the task. The signature below is a
-- suggestion - change it if you have a better one, but say why in NOTES.md.
--
-- It must, atomically:
--   * reject an amount that is not exactly the modal premium
--   * reject a payment on a policy that is beyond its revival window
--   * be safe when two requests for the same policy arrive at the same moment
--   * never record the same Idempotency-Key twice
--   * move NEXT_DUE_DATE forward by exactly one mode period
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SURAKSHA.RECORD_PAYMENT (
  P_POLICY_ID    IN  NUMBER,
  P_AMOUNT       IN  NUMBER,
  P_IDEM_KEY     IN  VARCHAR2,
  P_CHANNEL      IN  VARCHAR2 DEFAULT 'BRANCH',
  O_PAYMENT_ID   OUT NUMBER,
  O_NEXT_DUE     OUT DATE,
  O_RESULT       OUT VARCHAR2   -- e.g. RECORDED / ALREADY_RECORDED
) AS
BEGIN
  RAISE_APPLICATION_ERROR(-20099, 'RECORD_PAYMENT is not implemented yet');
END;
/

--------------------------------------------------------------------------------
-- V_POLICY_STATUS
--
-- Stub only. Implementing the derived-status query is part of the task.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW SURAKSHA.V_POLICY_STATUS AS
SELECT
  P.POLICY_ID,
  P.POLICY_NO,
  CAST(NULL AS VARCHAR2(20)) AS DERIVED_STATUS   -- TODO: implement
FROM SURAKSHA.POLICIES P;

EXIT;
