#!/bin/bash
# 95_reset_apps.sh  -  new apps VM, as root. Throws away the apps tier built by 30/40/60 so the clone can be
# practised again (pair it with 90_reset_db.sh on the database server). Without a VM snapshot this is the way
# back to "bare": stop, wait until every process of the tier has really gone, detach its Oracle homes from the
# inventory, delete NEW_BASE, drop the isolation rules, forget the step markers.
# 95_reset_apps.sh [--keep-copy]   keep the copied fs2/fs_ne (only FMW_Home and inst are removed): next run starts at 40
. "$(dirname "$0")/lib.sh"
need_root
not_prod
KEEP=no; [ "${1:-}" = "--keep-copy" ] && KEEP=yes
confirm "Delete the apps tier under $NEW_BASE on $(hostname -s)$([ $KEEP = yes ] && echo ' (keeping the copied files)')?" || die "not confirmed"

tier_pids() {  # every process of this tier: by command line, or by working directory (FNDLIBR shows no path)
  local p
  for p in $(pgrep -u "$APPS_OWNER"); do
    { tr '\0' ' ' < "/proc/$p/cmdline"; readlink "/proc/$p/cwd"; } 2>/dev/null | grep -q "$NEW_BASE/" && echo "$p"
  done
}

say "-- 1. stop the tier"
if [ -f "$NEW_BASE/EBSapps.env" ] && [ -n "$(tier_pids)" ]; then
  ask_secret AP "APPS password"; ask_secret WP "WebLogic password"
  printf 'apps\n%s\n%s\n' "$AP" "$WP" | WATCH_STDIN=1 run_watched "$LOG_DIR/adstpall_$(date +%H%M%S).log" \
    su - "$APPS_OWNER" -c ". '$NEW_BASE/EBSapps.env' run >/dev/null; \$ADMIN_SCRIPTS_HOME/adstpall.sh -nopromptmsg" || warn "adstpall returned non-zero"
  unset AP WP
fi
# adstpall only ASKS the managers to stop. Anything still alive after that (and its reviver.sh, which restarts
# the ICM when the database comes back) would keep a lock in the PDB: wait, then kill what is left.
for i in $(seq 1 30); do [ -z "$(tier_pids)" ] && break; sleep 10; done
LEFT=$(tier_pids)
if [ -n "$LEFT" ]; then
  warn "still running after 5 minutes, killing: $(ps -o pid=,comm= -p $(echo $LEFT | tr ' ' ',') | tr '\n' ' ')"
  kill $LEFT 2>/dev/null; sleep 10; LEFT=$(tier_pids); [ -n "$LEFT" ] && kill -9 $LEFT 2>/dev/null
fi
[ -z "$(tier_pids)" ] && ok "no process of $NEW_BASE left" || bad "processes of $NEW_BASE still running: $(tier_pids | tr '
' ' ')"
gate

say "-- 2. detach this tier's Oracle homes from $INV_LOC"
OUI=$(ls "$NEW_BASE"/fs2/FMW_Home/webtier/oui/bin/runInstaller 2>/dev/null | head -1)
# up to three passes: a home another home depends on (oracle_common <- webtier) only detaches once that one is gone
for pass in 1 2 3; do
  HOMES=$(grep -oE "<HOME [^>]*LOC=\"$NEW_BASE/[^\"]*\"" "$INV_LOC/ContentsXML/inventory.xml" | grep -oE "LOC=\"[^\"]*\"" | cut -d'"' -f2 | sort -u)
  [ -z "$HOMES" ] || [ -z "$OUI" ] && break
  for h in $HOMES; do
    su - "$APPS_OWNER" -c "$OUI -silent -waitForCompletion -detachHome ORACLE_HOME=$h -invPtrLoc /etc/oraInst.loc" >>"$LOG" 2>&1
    grep -q "<HOME [^>]*LOC=\"$h\"" "$INV_LOC/ContentsXML/inventory.xml" && say "   pass $pass: $h not detached yet (dependency), retrying" || ok "detached $h"
  done
done
check "inventory has no home under $NEW_BASE" bash -c "! grep -q '<HOME [^>]*LOC=\"$NEW_BASE/' '$INV_LOC/ContentsXML/inventory.xml'"

say "-- 3. delete"
if [ $KEEP = yes ]; then
  rm -rf "$NEW_BASE/fs2/FMW_Home" "$NEW_BASE/fs2/inst" "$NEW_BASE/fs_ne/inst" "$NEW_BASE/EBSapps.env"
  rm -f "$STATE_DIR"/40_* "$STATE_DIR"/60_* "$STATE_DIR"/pairs_target.txt
  ok "FMW_Home and inst removed, copied files kept: rerun from 40"
else
  rm -rf "$NEW_BASE"
  rm -f "$STATE_DIR"/30_* "$STATE_DIR"/40_* "$STATE_DIR"/60_* "$STATE_DIR"/need_spoof "$STATE_DIR"/*pairs*.txt
  ok "$NEW_BASE removed: rerun from 30"
fi

say "-- 4. isolation rules off"
systemctl disable --now ebsclone-isolation.service >>"$LOG" 2>&1
rm -f /etc/systemd/system/ebsclone-isolation.service /usr/local/sbin/ebsclone-isolation.sh; systemctl daemon-reload
while iptables -D OUTPUT -j EBSCLONE 2>/dev/null; do :; done
iptables -F EBSCLONE 2>/dev/null; iptables -X EBSCLONE 2>/dev/null
# rules from older kit versions sat directly in OUTPUT
for ip in $BLOCK_DB_IPS; do while iptables -D OUTPUT -p tcp -d "$ip" --dport 1521:1529 -j REJECT 2>/dev/null; do :; done; done
for ip in $BLOCK_ALL_IPS; do while iptables -D OUTPUT -d "$ip" -j REJECT 2>/dev/null; do :; done; done
check "isolation chain gone" bash -c "! iptables -S EBSCLONE >/dev/null 2>&1"
check "isolation boot unit gone" test ! -e /etc/systemd/system/ebsclone-isolation.service
N=0; for ip in $BLOCK_DB_IPS $BLOCK_ALL_IPS; do iptables -S OUTPUT | grep -q -- "-d $ip/32 .*REJECT" && N=$((N+1)); done
[ $N -eq 0 ] && ok "isolation rules removed" || bad "$N isolation rules still present"
gate
ok "apps tier reset. On the database server: 90_reset_db.sh"
