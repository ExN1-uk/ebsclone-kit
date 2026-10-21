#!/bin/bash
# 40_configure_apps.sh  -  new apps VM, as root (switches to applmgr for the EBS tools).
# 1. isolation: firewall rules so this VM can never reach PROD or DR, BEFORE any EBS tool runs
# 2. adcfgclone appsTier (about 30 minutes), with the release-file workaround only if 30 said it is needed
# 3. adcleansrccfg, then leak checks on the built configuration
. "$(dirname "$0")/lib.sh"
need_root
not_prod
CLONEBIN="$NEW_BASE/fs2/EBSapps/comn/clone/bin"
[ -f "$CLONEBIN/adcfgclone.pl" ] || die "no clone stage under $NEW_BASE (run 30_stage_apps.sh)"

say "-- 1. isolation: this VM must never reach the source's or PROD/DR's database listeners or apps hosts"
# Blocked: every database, host and address the source's own configuration names (30 recorded them from its move
# plan, pairs file and context file), resolved now. Nobody has to list production: whatever the source points at
# is what the copy must never reach. The new database and this VM are never blocked.
resolve() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }
[ -s "$STATE_DIR/source_db_hosts" ] || die "no record of what the source points at: rerun 30_stage_apps.sh"
SRC_DB_NAMES=$(cat "$STATE_DIR/source_db_hosts"); SRC_APP_NAMES=$(cat "$STATE_DIR/source_app_hosts")
LEAK_RE=$(source_leak_re)
KEEP=$( { resolve "$DB_SCAN"; resolve "$DB_HOST.$NET_DOMAIN"; echo "$DB_IP"; echo "$APPS_IP"; } | sort -u)
pick() { for ip in "$@"; do echo "$KEEP" | grep -qx "$ip" && { warn "$ip belongs to the new database or this VM: not blocked" >&2; continue; }; echo "$ip"; done | sort -u; }
DB_LIST=$(pick $(for n in $SRC_DB_NAMES; do resolve "$n"; done))
ALL_LIST=$(pick $(for n in $SRC_APP_NAMES; do resolve "$n"; done))
say "   source names found: $(echo $SRC_DB_NAMES $SRC_APP_NAMES)"
say "   database listeners blocked (1521-1529): $(echo $DB_LIST)"
say "   hosts blocked (all ports): $(echo $ALL_LIST)"
[ -n "$DB_LIST" ] || die "nothing to block: none of the source's database names resolves from here"

# The rules live in their own chain, written as a script that a systemd unit re-applies at every boot.
# 95_reset_apps.sh removes chain, script and unit.
ISO=/usr/local/sbin/ebsclone-isolation.sh; UNIT=/etc/systemd/system/ebsclone-isolation.service
{ echo '#!/bin/bash'
  echo "# written by ebsclone 40_configure_apps.sh on $(date '+%F %T'); removed by 95_reset_apps.sh"
  echo 'iptables -N EBSCLONE 2>/dev/null; iptables -F EBSCLONE'
  for ip in $DB_LIST; do echo "iptables -A EBSCLONE -p tcp -d $ip --dport 1521:1529 -j REJECT"; done
  for ip in $ALL_LIST; do echo "iptables -A EBSCLONE -d $ip -j REJECT"; done
  echo 'iptables -C OUTPUT -j EBSCLONE 2>/dev/null || iptables -I OUTPUT 1 -j EBSCLONE'
} > "$ISO"; chmod 700 "$ISO"
cat > "$UNIT" <<EOF
[Unit]
Description=ebsclone isolation: keep this EBS copy away from its source and PROD/DR
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ISO
[Install]
WantedBy=multi-user.target
EOF
# rules from older kit versions sat directly in OUTPUT: drop them, the chain replaces them
for ip in $DB_LIST; do while iptables -D OUTPUT -p tcp -d "$ip" --dport 1521:1529 -j REJECT 2>/dev/null; do :; done; done
for ip in $ALL_LIST; do while iptables -D OUTPUT -d "$ip" -j REJECT 2>/dev/null; do :; done; done
systemctl daemon-reload && systemctl enable ebsclone-isolation.service >>"$LOG" 2>&1 && systemctl restart ebsclone-isolation.service \
  || die "could not apply the isolation rules (systemctl status ebsclone-isolation)"
for ip in $DB_LIST; do check "$ip:1521 blocked" bash -c "! timeout 3 bash -c '</dev/tcp/$ip/1521' 2>/dev/null"; done
check "new database still reachable ($DB_SCAN:$DB_PORT)" timeout 5 bash -c "</dev/tcp/$DB_SCAN/$DB_PORT"
check "rules come back after a reboot (ebsclone-isolation.service enabled)" systemctl is-enabled -q ebsclone-isolation.service
gate
systemctl is-active -q firewalld && warn "firewalld is running: after a firewall-cmd --reload, run: systemctl restart ebsclone-isolation"

if ! is_done adcfgclone; then
  [ -e "$NEW_BASE/fs2/FMW_Home" ] || [ -e "$NEW_BASE/fs2/inst" ] && {
    confirm "A previous attempt left $NEW_BASE/fs2/FMW_Home or inst. Remove them and start again?" || die "stopped"
    rm -rf "$NEW_BASE/fs2/FMW_Home" "$NEW_BASE/fs2/inst"; }

  say "-- 2. adcfgclone appsTier, non-interactive: every answer comes from a pairs file, no questions to get wrong"
  # Oracle's documented form (adcfgclone.pl usage, 1383621.1):
  #   { echo <apps>; echo <wls>; } | perl adcfgclone.pl component=appsTier pairsfile=<file> addnode=no dualfs=no
  # The pairs file is the source's <context>_run.txt (30 fetched it) with every host, path, port and database
  # value replaced by this environment's. Anything left that names the source stops the step.
  CTX_NAME="${PDB}_${APPS_HOST}"; CFG_HOME="$NEW_BASE/fs2/inst/apps/$CTX_NAME"; URL="http://$APPS_HOST.$NET_DOMAIN:$WEB_PORT"
  PF="$STATE_DIR/pairs_target.txt"
  [ -s "$STATE_DIR/source_pairs.txt" ] || die "no source pairs file (30_stage_apps.sh fetches it)"
  SRCB=$(sed -n 's/^s_base=//p' "$STATE_DIR/source_pairs.txt")
  sed "s#${SRCB}/#${NEW_BASE}/#g; s#=${SRCB}\$#=${NEW_BASE}#" "$STATE_DIR/source_pairs.txt" > "$PF"
  setp() { grep -q "^$1=" "$PF" && sed -i "s#^$1=.*#$1=$2#" "$PF" || echo "$1=$2" >> "$PF"; }
  setp s_dbGlnam "$PDB";            setp s_dbSid "$PDB";            setp s_dbhost "$DB_HOST"
  setp s_dbdomain "$NET_DOMAIN";    setp s_dbport "$DB_PORT";       setp s_dbuser oracle
  setp s_file_edition_type run;     setp s_port_pool "$PORT_POOL";  setp s_shared_file_system false
  setp s_admhost "$APPS_HOST";      setp s_atName "$APPS_HOST";     setp s_smtphost "$APPS_HOST"
  setp s_smtpdomainname "$NET_DOMAIN"
  setp s_webentryurlprotocol http;  setp s_webentryhost "$APPS_HOST"; setp s_webentrydomain "$NET_DOMAIN"
  setp s_active_webport "$WEB_PORT"; setp s_external_url "$URL";    setp s_login_page "$URL/OA_HTML/AppsLogin"
  setp s_endUserMonitoringURL "$URL/oracle_smp_chronos/oracle_smp_chronos_sdk.gif"
  setp s_temp "$CFG_HOME/temp";     setp s_contextname "$CTX_NAME"; setp s_hostname "$APPS_HOST"
  setp s_domainname "$NET_DOMAIN";  setp s_cphost "$APPS_HOST";     setp s_webhost "$APPS_HOST"
  setp s_config_home "$CFG_HOME";   setp s_inst_base "$NEW_BASE"
  setp s_display "$APPS_HOST:0.0";  setp s_forms-c4ws_display "$APPS_HOST:0.0"; setp s_ohs_instance EBS_web_OHS1
  setp s_webport "$WEB_PORT";       setp s_http_listen_parameter "$WEB_PORT"; setp s_https_listen_parameter $((4443 + PORT_POOL))
  for s in s_web_applications_status s_web_entry_status s_apcstatus s_root_status s_batch_status s_adminserverstatus s_web_admin_status; do setp $s enabled; done
  setp s_other_service_group_status disabled
  chmod 644 "$PF"
  grep -vE '^#|^$|^\[' "$PF" | tee -a "$LOG" >/dev/null
  N=$(grep -v '^#' "$PF" | grep -ciE "$LEAK_RE")
  [ "$N" -eq 0 ] && ok "pairs file $PF has no source/PROD names" || { grep -v '^#' "$PF" | grep -iE "$LEAK_RE" | tee -a "$LOG"; die "$N source/PROD names left in $PF"; }
  check "pairs file has no empty instance values" bash -c "! grep -E '^s_(contextname|hostname|config_home|webport|display)=\$' '$PF'"
  gate
  say "   key answers: $(grep -E '^s_(dbSid|dbhost|dbport|hostname|base|port_pool|webport)=' "$PF" | tr '\n' ' ')"
  ask_secret AP "APPS password"; ask_secret WP "WebLogic password"
  ACLOG="$LOG_DIR/adcfgclone_$(date +%H%M%S).log"
  say "   The FMW build sits at 0% then 50% for many minutes: that is work, not a hang."
  printf '%s\n%s\n' "$AP" "$WP" | WATCH_STDIN=1 run_watched "$ACLOG" su - "$APPS_OWNER" -c \
    "cd '$CLONEBIN' && perl adcfgclone.pl component=appsTier pairsfile=$PF addnode=no dualfs=no"
  RC=$?
  [ $RC -eq 0 ] || warn "adcfgclone exited rc=$RC"
  L=$(ls -t "$NEW_BASE"/fs2/inst/apps/*/admin/log/clone/ApplyAppsTier_*.log 2>/dev/null | head -1)
  [ -n "$L" ] || die "no ApplyAppsTier log: adcfgclone did not get far (see $ACLOG)"
  check "AutoConfig completed successfully in $L" grep -q 'AutoConfig completed successfully' "$L"
  check "no tool exited with a non-zero status" bash -c "! grep -qE 'exiting with status [1-9]' '$L'"
  gate
  done_mark adcfgclone
fi

say "-- 3. clean out the source's settings (adcleansrccfg, about 3 minutes)"
if ! is_done adcleansrccfg; then
  [ -n "${AP:-}" ] || ask_secret AP "APPS password"; [ -n "${WP:-}" ] || ask_secret WP "WebLogic password"
  # it reads APPS then WebLogic from stdin with no prompt text
  CLLOG="$LOG_DIR/adcleansrccfg_$(date +%H%M%S).log"
  printf '%s\n%s\n' "$AP" "$WP" | WATCH_STDIN=1 run_watched "$CLLOG" su - "$APPS_OWNER" -c \
    ". '$NEW_BASE/EBSapps.env' run >/dev/null; perl \$AD_TOP/patch/115/bin/adcleansrccfg.pl context=\$CONTEXT_FILE" \
    || warn "adcleansrccfg returned non-zero (normal when it only failed to delete ISGDatasource): read $CLLOG"
  [ "$(grep -c . "$CLLOG" 2>/dev/null)" -gt 3 ] || die "adcleansrccfg did not run (log $CLLOG nearly empty)"
  say "   'could not delete ISGDatasource' and 'Errors were encountered in cleanup' are normal"
  done_mark adcleansrccfg
fi
unset AP WP

say "-- 4. leak checks on what was built"
J="$NEW_BASE/fs2/FMW_Home/user_projects/domains/EBS_domain/config/jdbc"
grep -rhoE 'jdbc:oracle:thin:@[^<]*' "$J"/*.xml | sort -u | tee -a "$LOG"
check "every JDBC URL names $SERVICE" bash -c "! grep -rhoE 'jdbc:oracle:thin:@[^<]*' '$J'/*.xml | grep -v '$SERVICE' | grep -q ."
check "no source/PROD names in the data sources" bash -c "! grep -rhoE 'jdbc:oracle:thin:@[^<]*' '$J'/*.xml | grep -qiE '$LEAK_RE'"
CTX=$(ls "$NEW_BASE"/fs2/inst/apps/*/appl/admin/*.xml 2>/dev/null | head -1)
check "context s_dbSid = $PDB" grep -q "oa_var=\"s_dbSid\">$PDB<" "$CTX"
check "context s_webport = $WEB_PORT" grep -qE "oa_var=\"s_webport\"[^>]*>$WEB_PORT<" "$CTX"
N=$(grep -ciE "$LEAK_RE" "$CTX"); [ "$N" -eq 0 ] && ok "context file clean" || warn "$N lines in the context file still mention source/PROD names: review them ($CTX)"
gate
ok "apps tier configured, not started. Next: 50_safety_gate.sh on the database server"
