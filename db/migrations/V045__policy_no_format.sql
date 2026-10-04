WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V045: policy numbers must be stored upper case, no stray spaces

-- Found by db/analysis/02_verify_migrations.sql (test B13): V040 cleaned the
-- existing policy numbers, but a NEW 'sl-2024-000101' still got past the
-- unique rule, because Oracle compares case-sensitively. That is how the
-- legacy duplicate SL-2024-000120 / sl-2024-000120 happened.
-- All existing rows are already clean (V040), so this check is fully validated.
ALTER TABLE POLICIES ADD CONSTRAINT CK_POL_POLICY_NO_FORMAT
  CHECK (POLICY_NO = UPPER(TRIM(POLICY_NO)));

COMMIT;
EXIT
