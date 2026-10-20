#!/bin/bash
# 90_reset_db.sh  -  database server, as oracle. Puts the PDB back exactly as it was before 20_db_prepare.sh
# 90_reset_db.sh [--final]   --final also drops the restore point when you are finished for good.
# (flashback to RESTORE_POINT, then the open mode and services 20 recorded). Use after a rehearsal, together
# with 95_reset_apps.sh (or rolling the VM back to its OS snapshot).
# Stop the apps tier on the VM first, or its sessions are killed.
. "$(dirname "$0")/lib.sh"
need_user oracle
not_prod
db_env
BEFORE="$STATE_DIR/${PDB}_before.txt"
MODE=$(sed -n 's/^MODE //p' "$BEFORE" 2>/dev/null)
[ -n "$MODE" ] || warn "no record of how $PDB was found ($BEFORE): it will be left MOUNTED"
confirm "Flash $PDB back to $RESTORE_POINT? Everything done to it since is lost." || die "not confirmed"
sys_sql <<SQL | tee -a "$LOG"
whenever sqlerror exit failure
alter pluggable database ${PDB} close immediate;
flashback pluggable database ${PDB} to restore point ${RESTORE_POINT};
alter pluggable database ${PDB} open resetlogs;
alter pluggable database ${PDB} close immediate;
alter pluggable database ${PDB} discard state;
SQL
[ "${PIPESTATUS[0]}" -eq 0 ] || die "flashback failed"
if [ "$MODE" = "READ WRITE" ]; then
  # it was open when we found it: reopen, restart the services it was running, keep that as its saved state
  { echo "whenever sqlerror exit failure"
    echo "alter pluggable database ${PDB} open;"
    echo "alter session set container=${PDB};"
    sed -n 's/^SVC //p' "$BEFORE" | while read -r s; do
      echo "begin dbms_service.start_service('$s'); exception when others then if sqlcode not in (-44305,-44773) then raise; end if; end;"
      echo "/"
    done
    echo "alter pluggable database ${PDB} save state;"
  } | sys_sql | tee -a "$LOG"
  [ "${PIPESTATUS[1]}" -eq 0 ] || die "reopen failed"
fi
OUT=$(sys_sql <<SQL
set heading off feedback off pages 0 lines 200
select 'MODE '||open_mode from v\$pdbs where name='${PDB}';
select 'SVC '||s.name from v\$active_services s join v\$pdbs p on p.con_id=s.con_id where p.name='${PDB}';
SQL
)
echo "$OUT" | tee -a "$LOG"
if [ -n "$MODE" ]; then
  check "$PDB open mode as found ($MODE)" bash -c "echo \"$OUT\" | grep -qx 'MODE ${MODE:-MOUNTED}'"
  for s in $(sed -n 's/^SVC //p' "$BEFORE"); do check "service $s running again" bash -c "echo \"$OUT\" | grep -qix 'SVC $s'"; done
fi
rm -f "$STATE_DIR"/20_db_prepare.datapatch "$STATE_DIR"/20_db_prepare.neutralise "$STATE_DIR"/25_db_register.*
gate
if [ "${1:-}" = "--final" ]; then
  # finished for good: no restore point left behind, no record of the old state
  echo "drop restore point ${RESTORE_POINT} for pluggable database ${PDB};" | sys_sql | tee -a "$LOG"
  rm -f "$BEFORE" "$STATE_DIR/20_db_prepare.restore_point"
  ok "$PDB is back as it was found (${MODE:-MOUNTED}); restore point $RESTORE_POINT dropped."
else
  ok "$PDB is back to $RESTORE_POINT and as it was found (${MODE:-MOUNTED}). The restore point is kept for the next rehearsal."
  say "   Finished for good? Run 90_reset_db.sh --final instead (also drops the restore point)."
fi
