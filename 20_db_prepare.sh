#!/bin/bash
# 20_db_prepare.sh  -  database server, as oracle. CHANGES the PDB.
# Takes a guaranteed restore point first (so everything after this can be undone with 90_reset_db.sh),
# opens the PDB, patches it to the home's level if needed, and makes it safe: running requests ended,
# pending requests held, file folders created.
. "$(dirname "$0")/lib.sh"
need_user oracle
not_prod
db_env
mkdir -p "$WORK_DIR"

echo
echo "This changes $PDB in $CDB_NAME on $(hostname). It belongs to the DBA: you must have their OK."
confirm "Do you have the DBA's go to use $PDB and take restore point $RESTORE_POINT?" || die "not confirmed"

# how the DBA left the PDB (open mode + running services): 90_reset_db.sh puts it back exactly so
BEFORE="$STATE_DIR/${PDB}_before.txt"
if [ ! -s "$BEFORE" ]; then
  sys_sql <<SQL | grep -E '^(MODE|SVC) ' > "$BEFORE"
set heading off feedback off pages 0 lines 200
select 'MODE '||open_mode from v\$pdbs where name='${PDB}';
select 'SVC '||s.name from v\$active_services s join v\$pdbs p on p.con_id=s.con_id where p.name='${PDB}';
SQL
  say "   as found: $(tr '\n' ' ' < "$BEFORE")"
fi

if ! is_done restore_point; then
  say "-- 1. guaranteed restore point $RESTORE_POINT (before the first change)"
  sys_sql <<SQL | tee -a "$LOG"
whenever sqlerror exit failure
create restore point ${RESTORE_POINT} for pluggable database ${PDB} guarantee flashback database;
select name, guarantee_flashback_database, pdb_restore_point from v\$restore_point where name='${RESTORE_POINT}';
SQL
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "could not create the restore point"
  done_mark restore_point; ok "restore point taken"
fi

say "-- 2. open"
sys_sql <<SQL | tee -a "$LOG"
begin
  for r in (select 1 from v\$pdbs where name='${PDB}' and open_mode='MOUNTED') loop
    execute immediate 'alter pluggable database ${PDB} open';
  end loop;
end;
/
select name, open_mode, restricted from v\$pdbs where name='${PDB}';
SQL
RESTRICTED=$(echo "select restricted from v\$pdbs where name='${PDB}';" | sys_sql | grep -E 'YES|NO' | tr -d ' ')

if [ "$RESTRICTED" = "YES" ] && ! is_done datapatch; then
  say "-- 3. $PDB opened RESTRICTED: its SQL patches are behind the home. Running datapatch (about 8 min)."
  say "   A first-pass ORA-00060 deadlock on the Data Pump bundle is normal; datapatch retries it."
  run_watched "$WORK_DIR/datapatch_${PDB}.log" "$DB_OH/OPatch/datapatch" -verbose -pdbs "$PDB" || die "datapatch failed, see $WORK_DIR/datapatch_${PDB}.log"
  grep -q 'SQL Patching tool complete' "$WORK_DIR/datapatch_${PDB}.log" || die "datapatch did not complete"
  sys_sql <<SQL | tee -a "$LOG"
alter pluggable database ${PDB} close immediate;
alter pluggable database ${PDB} open;
SQL
  done_mark datapatch
fi

say "-- 4. state checks"
OUT=$(sys_sql <<SQL
set heading off feedback off pages 0 lines 200
select 'MODE '||open_mode||' '||restricted from v\$pdbs where name='${PDB}';
select 'VIOL '||type||' '||cause from pdb_plug_in_violations where name='${PDB}' and status<>'RESOLVED' and type='ERROR';
alter session set container=${PDB};
select 'REL '||release_name from apps.fnd_product_groups;
SQL
)
echo "$OUT" | tee -a "$LOG"
check "$PDB READ WRITE, not restricted" bash -c "echo \"$OUT\" | grep -q '^MODE READ WRITE NO'"
check "no ERROR plug-in violations" bash -c "! echo \"$OUT\" | grep -q '^VIOL'"
check "EBS release 12.2.15" bash -c "echo \"$OUT\" | grep -q '^REL 12.2.15'"
gate

if ! is_done neutralise; then
  say "-- 5. end copied running requests, hold pending ones, create the file folders (back end / database update)"
  mkdir -p "$DB_OH/temp/$PDB"
  sys_sql <<SQL | tee -a "$LOG"
whenever sqlerror exit failure
set lines 200
alter session set container=${PDB};
select count(*) running_at_copy from apps.fnd_concurrent_requests where phase_code='R';
update apps.fnd_concurrent_requests set phase_code='C', status_code='E', actual_completion_date=sysdate where phase_code='R';
update apps.fnd_concurrent_requests set hold_flag='Y' where phase_code='P';
commit;
create or replace directory EBS_UTL_FILE_DIR_${PDB} as '${DB_OH}/temp/${PDB}';
create or replace directory EBS_UTL_FILE_DIR_${PDB}_OUT as '${DB_OH}/appsutil/outbound/${DB_TAG}';
alter pluggable database ${PDB} save state;
select 'neutralise done' from dual;
SQL
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "neutralise step failed"
  done_mark neutralise
fi
ok "$PDB prepared. Next: 25_db_register.sh"
