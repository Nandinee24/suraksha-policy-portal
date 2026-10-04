WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V060: customer PAN and name cleanup

-- PAN: one format. Names: trim and collapse repeated spaces; casing kept as
-- entered (search handles case). E.g. 'Rajesh  Patel ' -> 'Rajesh Patel'.
UPDATE CUSTOMERS
SET PAN       = UPPER(TRIM(PAN)),
    FULL_NAME = REGEXP_REPLACE(TRIM(FULL_NAME), '\s{2,}', ' ');

ALTER TABLE CUSTOMERS MODIFY (FULL_NAME NOT NULL, PAN NOT NULL);

-- PAN format: 5 letters, 4 digits, 1 letter.
ALTER TABLE CUSTOMERS ADD CONSTRAINT CK_CUST_PAN_FORMAT CHECK (REGEXP_LIKE(PAN, '^[A-Z]{5}[0-9]{4}[A-Z]$'));

-- No UNIQUE on PAN: 1152 and 1153 share the dummy PAN ABCDE1234F (likely the
-- same person entered twice). Merging customers is a KYC decision, not a
-- migration. No index for name search either: the search is LIKE '%text%',
-- which a normal index cannot use.

COMMIT;
EXIT