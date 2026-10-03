WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V020: normalise free-text PREMIUM_MODE into MODE_CODE (Y/H/Q/M)

ALTER TABLE POLICIES ADD (MODE_CODE CHAR(1));

-- Explicit list of every spelling found by db/analysis/00_profile.sql (query 2).
-- UPPER(TRIM()) removes case and stray spaces before matching.
UPDATE POLICIES
SET MODE_CODE = CASE
    WHEN UPPER(TRIM(PREMIUM_MODE)) IN ('Y', 'YLY', 'YEARLY', 'ANNUAL')                               THEN 'Y'
    WHEN UPPER(TRIM(PREMIUM_MODE)) IN ('H', 'HY', 'HLY', 'HALF-YEARLY', 'HALF YEARLY', 'SEMI-ANNUAL') THEN 'H'
    WHEN UPPER(TRIM(PREMIUM_MODE)) IN ('Q', 'QLY', 'QTR', 'QUARTERLY')                               THEN 'Q'
    WHEN UPPER(TRIM(PREMIUM_MODE)) IN ('M', 'MLY', 'MTH', 'MONTHLY')                                 THEN 'M'
  END;

ALTER TABLE POLICIES MODIFY (MODE_CODE NOT NULL);
ALTER TABLE POLICIES ADD CONSTRAINT CK_POL_MODE_CODE CHECK (MODE_CODE IN ('Y', 'H', 'Q', 'M'));

COMMIT;
EXIT