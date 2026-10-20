#!/bin/bash
# 60_start_verify.sh  -  new apps VM, as applmgr. Starts the apps tier and proves it works.
. "$(dirname "$0")/lib.sh"
need_user "$APPS_OWNER"
not_prod
# shellcheck disable=SC1090
. "$NEW_BASE/EBSapps.env" run >/dev/null 2>&1 || die "cannot load $NEW_BASE/EBSapps.env"
unset -f which 2>/dev/null   # OL8 profile function that makes EBS scripts print harmless 'which' errors

confirm "Has 50_safety_gate.sh passed on the database server?" || die "run the safety gate first"
ask_secret AP "APPS password"; ask_secret WP "WebLogic password"

say "-- 0. no other concurrent manager may be attached to $PDB (else the new ICM dies with AFPCSQ / 'giving up')"
# Seen in a rehearsal: an older apps tier's ICM, still exiting after adstpall when txk bounced the
# CDB, was restarted by its reviver.sh and held the ICM lock. adstpall only REQUESTS the manager shutdown.
OUT=$(printf 'connect apps/"%s"@%s\nset heading off feedback off pages 0 lines 200\nselect '"'"'CM '"'"'||machine||'"'"' '"'"'||program||'"'"' '"'"'||module from gv$session where module like '"'"'e::cp%%'"'"' or program like '"'"'ICM@%%'"'"' or program like '"'"'FNDLIBR%%'"'"';\nexit\n' \
      "$AP" "//$DB_SCAN:$DB_PORT/$SERVICE" | sqlplus -s -L /nolog)
if echo "$OUT" | grep -q '^CM '; then
  echo "$OUT" | grep '^CM ' | tee -a "$LOG"
  die "concurrent manager sessions from another apps tier are connected to $PDB (above). Stop that tier (and its reviver.sh) first."
fi
ok "no other concurrent manager attached"

say "-- 1. start (adstrtal 'exiting with status 0' only means the start was accepted)"
printf 'apps\n%s\n%s\n' "$AP" "$WP" | WATCH_STDIN=1 run_watched "$LOG_DIR/adstrtal_$(date +%H%M%S).log" \
  "$ADMIN_SCRIPTS_HOME/adstrtal.sh" -nopromptmsg || warn "adstrtal returned non-zero: check the log; some services may still be up"

say "-- 2. login page"
URL="http://$APPS_HOST.$NET_DOMAIN:$WEB_PORT/OA_HTML/AppsLocalLogin.jsp"
for i in $(seq 1 20); do
  C=$(curl -s -o /dev/null -w '%{http_code}' -L "$URL"); [ "$C" = 200 ] && break; sleep 15
done
[ "$C" = 200 ] && ok "$URL answers 200" || bad "$URL answers $C"
F=$(curl -s -o /dev/null -w '%{http_code}' "http://$APPS_HOST.$NET_DOMAIN:$WEB_PORT/forms/frmservlet")
[ "$F" = 200 ] && ok "Forms servlet answers 200" || bad "Forms servlet answers $F (forms managed server down?)"

say "-- 3. this node is registered in the database with the server id the apps tier uses (else Forms: 'Node id does not exist')"
DBC=$(ls "$FND_SECURE"/*.dbc | head -1)
SID=$(grep -E '^APPL_SERVER_ID=' "$DBC" | cut -d= -f2)
OUT=$(printf 'connect apps/"%s"@%s\nset heading off feedback off pages 0\nselect node_name||'"'"' '"'"'||count(*) from fnd_nodes where server_id='"'"'%s'"'"' group by node_name;\nexit\n' \
      "$AP" "//$DB_SCAN:$DB_PORT/$SERVICE" "$SID" | sqlplus -s -L /nolog)
echo "   $OUT" | tee -a "$LOG"
check "fnd_nodes has this node with the DBC's APPL_SERVER_ID" bash -c "echo \"$OUT\" | grep -qi '${APPS_HOST} 1'"

say "-- 4. concurrent managers (give them 5 minutes)"
sleep 120
OUT=$(printf 'connect apps/"%s"@%s\nset heading off feedback off pages 0 lines 200\nselect concurrent_queue_name||'"'"' '"'"'||max_processes||'"'"' '"'"'||running_processes from fnd_concurrent_queues where enabled_flag='"'"'Y'"'"' and (max_processes>0 or running_processes>0) order by 1;\nexit\n' \
      "$AP" "//$DB_SCAN:$DB_PORT/$SERVICE" | sqlplus -s -L /nolog)
echo "$OUT" | sed 's/^/   /' | tee -a "$LOG"
check "every manager runs its target number of processes" bash -c "echo \"$OUT\" | awk 'NF==3 && \$2!=\$3{bad=1} END{exit bad}'"
# FNDLIBR's command line is just 'FNDLIBR'; its working directory ($APPLCSF/log) tells which tier it belongs to
N=0; for p in $(pgrep -u "$APPS_OWNER" -x 'FNDLIBR|FNDSM|FNDCRM'); do readlink "/proc/$p/cwd" | grep -q "^$NEW_BASE/" && N=$((N+1)); done
check "manager processes running on this VM ($N)" test "$N" -gt 0
unset AP WP
gate
ok "DONE. Log in at http://$APPS_HOST.$NET_DOMAIN:$WEB_PORT as SYSADMIN and open a form."
say "   Each PC that opens forms needs http://$APPS_HOST.$NET_DOMAIN:$WEB_PORT in the Java Exception Site List."
