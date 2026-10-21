#!/bin/bash
# 01_check_db.sh  -  database server, as oracle. Read-only: changes nothing.
. "$(dirname "$0")/lib.sh"
need_user oracle
not_prod
db_env

say "-- container and PDB"
OUT=$(sys_sql <<SQL
set heading off feedback off pages 0 lines 200
select 'PDB '||name||' '||open_mode||' '||restricted from v\$pdbs where name='${PDB}';
select 'LOG '||log_mode from v\$database;
select 'RP '||name from v\$restore_point where name='${RESTORE_POINT}';
select 'FRA '||round(space_used/space_limit*100) from v\$recovery_file_dest;
select 'VIOL '||type||' '||substr(message,1,100) from pdb_plug_in_violations where name='${PDB}' and status<>'RESOLVED' and type='ERROR';
select 'VWARN '||count(*) from pdb_plug_in_violations where name='${PDB}' and status<>'RESOLVED' and type<>'ERROR';
select 'OTHER '||name||' '||open_mode from v\$pdbs where name not in ('PDB\$SEED','${PDB}');
SQL
)
echo "$OUT" | grep -v "^VWARN" | tee -a "$LOG"
NW=$(echo "$OUT" | sed -n "s/^VWARN //p")
[ "${NW:-0}" -gt 0 ] && say "   $NW plug-in WARNINGs (old service names carried over from the source database: harmless, not listed)"
check "$PDB exists" bash -c "echo \"$OUT\" | grep -q '^PDB $PDB'"
check "archivelog mode (needed for a guaranteed restore point)" bash -c "echo \"$OUT\" | grep -q '^LOG ARCHIVELOG'"
FRA=$(echo "$OUT" | awk '/^FRA/{print $2}')
check "recovery area below 80% (now ${FRA}%)" test "${FRA:-100}" -lt 80
echo "$OUT" | grep -q "^RP $RESTORE_POINT" && ok "restore point $RESTORE_POINT exists" || warn "restore point $RESTORE_POINT not taken yet (20_db_prepare.sh takes it)"
U=$(pdb_in_use | tr '
' ' ')
[ -z "$U" ] && ok "no application server is using $PDB right now" || bad "$PDB is in use right now from: $U(a live system, or a copy whose apps tier still runs: stop that first)"
echo "$OUT" | grep -q '^VIOL ERROR' && warn "plug-in violations of type ERROR: usually means datapatch has not run on this PDB (20 handles it)"

say "-- EBS database-tier tools in $DB_OH"
check "txkPostPDBCreationTasks.pl present" test -f "$DB_OH/appsutil/bin/txkPostPDBCreationTasks.pl"
check "txkSetCfgCDB.env present" test -f "$DB_OH/appsutil/txkSetCfgCDB.env"
check "appsutil/jre points at a JDK" test -x "$DB_OH/appsutil/jre/bin/java"
check "Grid listener has USE_SID_AS_SERVICE_LISTENER=ON (else txk stops at 'Enter Hostname')" grep -qi 'USE_SID_AS_SERVICE_LISTENER *= *ON' "$GRID_LISTENER"
check "home has 5 GB free" bash -c "[ \$(df --output=avail --block-size=1G '$DB_OH' | tail -1 | tr -d ' ') -ge 5 ]"
say "   RDBMS patch level: $($DB_OH/OPatch/opatch lspatches 2>/dev/null | grep -m1 -i 'Database Release Update')"
gate
