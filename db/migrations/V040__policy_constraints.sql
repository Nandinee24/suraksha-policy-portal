WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V040: policy keys, foreign key, date rule

-- Every policy has these in the legacy data; make them mandatory from now on.
ALTER TABLE POLICIES MODIFY (POLICY_NO NOT NULL, CUSTOMER_ID NOT NULL, COMMENCEMENT_DATE NOT NULL);

-- Policy numbers: one format (upper case, no stray spaces).
UPDATE POLICIES SET POLICY_NO = UPPER(TRIM(POLICY_NO));

-- Unique policy number. 5019 and 5020 both hold SL-2024-000120 (different
-- customers) -> ORA-02299. Renumbering is wrong (the number is printed on the
-- customer's bond), so: NOVALIDATE keeps that pair, blocks any NEW duplicate.
-- NOVALIDATE unique needs a NON-unique index behind it.
-- Index also serves: lookup/search by policy number.
CREATE INDEX IX_POL_POLICY_NO ON POLICIES (POLICY_NO);
ALTER TABLE POLICIES ADD CONSTRAINT UQ_POL_POLICY_NO UNIQUE (POLICY_NO)
  USING INDEX IX_POL_POLICY_NO ENABLE NOVALIDATE;

-- Policy -> customer. 5021 points to customer 999999 which does not exist
-- -> ORA-02298. The policy is a real contract with premiums owed, so it stays
-- visible and payable; NOVALIDATE protects all new rows.
ALTER TABLE POLICIES ADD CONSTRAINT FK_POL_CUSTOMER
  FOREIGN KEY (CUSTOMER_ID) REFERENCES CUSTOMERS (CUSTOMER_ID) ENABLE NOVALIDATE;

-- Index on the foreign key. Serves: the POLICIES-CUSTOMERS join in the list
-- and detail queries; also stops Oracle locking the whole POLICIES table when
-- a customer row is deleted or its key changes.
CREATE INDEX IX_POL_CUSTOMER_ID ON POLICIES (CUSTOMER_ID);

-- The oldest unpaid due date cannot be after the next due date.
-- 5008/5009/5010 break this -> ORA-02293. They are exactly the 2-year
-- revival-window cases (first unpaid 729/730/731 days ago) and R7 says the
-- window is measured from FIRST_UNPAID_DUE_DATE, so they are kept as-is.
ALTER TABLE POLICIES ADD CONSTRAINT CK_POL_DUE_DATES
  CHECK (FIRST_UNPAID_DUE_DATE IS NULL OR FIRST_UNPAID_DUE_DATE <= NEXT_DUE_DATE) ENABLE NOVALIDATE;

COMMIT;
EXIT