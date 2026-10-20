#!/bin/bash
# 25_db_register.sh  -  database server, as oracle. Registers the PDB with EBS (txkPostPDBCreationTasks:
# service, network files, AutoConfig), then repairs what txk is known to break.
# Usage (as root): 25_db_register.sh [/path/to/appsutil.zip]
#   Without an argument it picks up the appsutil.zip that 05_source_preclone.sh made on the source (one prompt for
#   the source's root password). No zip there (05 skipped), or no access: it carries on with the appsutil already
#   in $DB_OH. Either way the step runs; it never stops over this.
# Run it as root. The source's root password is asked here, while the step still has your terminal (after su to
# oracle, ssh cannot reach the terminal and would answer its own prompt). Then it carries on as oracle by itself.
ARG="${1:-}"; [ "$ARG" = "--from-source" ] && ARG=""   # older guides passed this; picking up is now the default
if [ "$(id -u)" -eq 0 ]; then
  # shellcheck disable=SC1090
  . "${VARS:-/u01/ebsclone/clone.vars}"
  if [ -z "$ARG" ] && [ ! -e "$STATE_DIR/25_db_register.appsutil" ] && [ ! -e "$STATE_DIR/25_db_register.txk" ]; then
    mkdir -p "$WORK_DIR"; chown oracle:oinstall "$WORK_DIR"; Z="$WORK_DIR/appsutil.zip"; rm -f "$Z"
    echo "Database tools from the source: picking up the appsutil.zip that step 05 made on $SRC_HOST, if it is there."
    echo "The next prompt wants the root password of the SOURCE ($SRC_HOST), not of this database server."
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$SRC_HOST" \
      "f=\$(ls -t $SRC_BASE/fs2/inst/apps/*/admin/out/appsutil.zip 2>/dev/null | head -1); [ -n \"\$f\" ] && cat \"\$f\"" > "$Z"
    if [ -s "$Z" ] && unzip -tq "$Z" >/dev/null 2>&1; then
      chown oracle:oinstall "$Z"; ARG="$Z"; echo "appsutil.zip picked up from the source ($(du -h "$Z" | cut -f1))."
    else
      rm -f "$Z"; ARG="--no-source"
      echo "No appsutil.zip picked up (step 05 not run, or no access): carrying on with the appsutil already in $DB_OH."
    fi
  fi
  exec su - oracle -c "$(readlink -f "$0") $ARG"
fi

. "$(dirname "$0")/lib.sh"
need_user oracle
not_prod

ZIP="$ARG"
[ "$ZIP" = "--no-source" ] && { ZIP=""; ok "using the appsutil already in $DB_OH"; }
if [ -n "$ZIP" ] && ! is_done appsutil; then
  say "-- 1. refresh appsutil from $ZIP"
  [ -r "$ZIP" ] || die "cannot read $ZIP"
  ( cd "$DB_OH" && unzip -o -q "$ZIP" ) || die "unzip failed"
  ln -sfn "$DB_OH/jdk" "$DB_OH/appsutil/jre"
  mkdir -p "$DB_OH/appsutil/jlib" && cp "$DB_OH/jdbc/lib/ojdbc8.jar" "$DB_OH/lib/xmlparserv2.jar" "$DB_OH/appsutil/jlib/"
  done_mark appsutil; ok "appsutil refreshed"
fi

grep -qi 'USE_SID_AS_SERVICE_LISTENER *= *ON' "$GRID_LISTENER" || die "USE_SID_AS_SERVICE_LISTENER=ON missing in $GRID_LISTENER (as root/grid: add it, reload the listener)"

ask_secret AP "APPS password"
is_done txk || ask_secret SP "SYSTEM password (CDB)"
export ORACLE_HOME="$DB_OH" ORACLE_SID="$CDB_SID"
export PATH="$ORACLE_HOME/perl/bin:$ORACLE_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$ORACLE_HOME/lib:$ORACLE_HOME/appsutil/jre/lib"
export PERL5LIB="$ORACLE_HOME/appsutil/perl:$(ls -d $ORACLE_HOME/perl/lib/*/ | tr '\n' ':')$ORACLE_HOME/perl/lib"
cd "$ORACLE_HOME/appsutil" && . ./txkSetCfgCDB.env -dboraclehome="$ORACLE_HOME" >/dev/null
cd "$ORACLE_HOME/appsutil/bin"
# done once: a rerun after a later check failed must not restart the CDB again
if ! is_done txk; then
say "-- 2. txkPostPDBCreationTasks (about 12 minutes, restarts the whole CDB: every PDB in it blinks)"
warn "the CDB restarts open every PDB in it; step 4 closes $OTHER_PDBS again"
TXKLOG="$WORK_DIR/txk_${PDB}_$(date +%H%M%S).log"
# passwords go on stdin (APPS, then SYSTEM): never on the command line, never in a file
printf '%s\n%s\n' "$AP" "$SP" | WATCH_STDIN=1 run_watched "$TXKLOG" perl txkPostPDBCreationTasks.pl -dboraclehome="$ORACLE_HOME" \
  -cdbname="$CDB_NAME" -cdbsid="$CDB_SID" -dbuniquename="$CDB_UNIQUE" -pdbsid="$PDB" -dbport="$DB_PORT" \
  -outdir="$ORACLE_HOME/appsutil/log" -appsuser=APPS -israc=no -promptmsg=yes
RC=$?
unset SP
[ $RC -eq 0 ] || warn "txk exited rc=$RC"
if ! grep -q 'AutoConfig completed successfully' "$TXKLOG"; then
  grep -i 'Directory object does not exist' -r "$ORACLE_HOME/appsutil/log/$DB_TAG" 2>/dev/null | tail -3 | tee -a "$LOG"
  die "AutoConfig did not complete successfully. A missing directory object is the usual cause: create it in $PDB, then rerun AutoConfig ($ORACLE_HOME/appsutil/scripts/$DB_TAG/adautocfg.sh)."
fi
ok "txk + AutoConfig completed"
done_mark txk
fi

say "-- 3. old password versions (BL-001): txk resets them to 10, the 10.1.2 client needs 8"
for f in "$ORACLE_HOME/network/admin/sqlnet.ora" "$ORACLE_HOME/network/admin/$DB_TAG/sqlnet.ora"; do
  [ -f "$f" ] || continue
  sed -i 's/^SQLNET.ALLOWED_LOGON_VERSION_SERVER *= *10 *$/SQLNET.ALLOWED_LOGON_VERSION_SERVER=8/' "$f"
  grep -q '^SQLNET.ALLOWED_LOGON_VERSION_CLIENT' "$f" || printf '\nSQLNET.ALLOWED_LOGON_VERSION_CLIENT=8\n' >> "$f"
  check "$f SERVER=8 and CLIENT=8" bash -c "grep -q 'SERVER=8' '$f' && grep -q 'CLIENT=8' '$f'"
done

say "-- 4. close the PDBs txk opened, test file writing and the APPS login"
# close only the ones that are open (a rerun finds them closed already)
for p in $OTHER_PDBS; do
  printf "begin for r in (select 1 from v\$pdbs where name='%s' and open_mode<>'MOUNTED') loop execute immediate 'alter pluggable database %s close immediate'; end loop; end;\n/\n" "$p" "$p"
done | sys_sql | tee -a "$LOG"
OUT=$(sys_sql <<SQL
set heading off feedback off pages 0 lines 200
select 'PDB '||name||' '||open_mode from v\$pdbs;
alter session set container=${PDB};
set serveroutput on
select 'APPLPTMP '||directory_path from dba_directories where directory_name='EBS_APPLPTMP';
declare f utl_file.file_type; begin f := utl_file.fopen('EBS_APPLPTMP','${PDB}_fopen_test.txt','w'); utl_file.put_line(f,'ok'); utl_file.fclose(f); dbms_output.put_line('FOPEN OK'); end;
/
SQL
)
echo "$OUT" | tee -a "$LOG"
check "$PDB READ WRITE" bash -c "echo \"$OUT\" | grep -q '^PDB $PDB READ WRITE'"
for p in $OTHER_PDBS; do check "$p closed again" bash -c "echo \"$OUT\" | grep -q '^PDB $p MOUNTED'"; done
check "EBS_APPLPTMP writable" bash -c "echo \"$OUT\" | grep -q 'FOPEN OK'"
apps_login_ok "$AP" "//$DB_SCAN:$DB_PORT/$SERVICE" && ok "APPS can log in over the new service" || bad "APPS cannot log in over //$DB_SCAN:$DB_PORT/$SERVICE"
unset AP
gate
ok "database registered. Next: 30_stage_apps.sh on the VM"
