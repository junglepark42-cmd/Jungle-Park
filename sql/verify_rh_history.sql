-- Must return zero differences for each source table after the additive migration.
select b.table_name,
 (select count(*) from jsonb_array_elements(b.rows)) as saved_rows,
 (select count(*) from jsonb_array_elements(b.rows) old where not exists (
 select 1 from public.planning p where b.table_name='planning' and (to_jsonb(p)-'emp_id'-'contract_id')=old
 )) as differences
from rh_private.backup_20261102 b where b.table_name='planning';
select count(*) as contracts_imported from rh_private.contracts where source='legacy_import';
select count(*) as shifts_without_employee from public.planning where emp_id is null;
