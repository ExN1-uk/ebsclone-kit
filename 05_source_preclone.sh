#!/bin/bash
# 05_source_preclone.sh  -  SOURCE apps host, as applmgr. Read-only for the running system: refreshes the clone
# stage (adpreclone appsTier) and makes appsutil.zip for the database tier (admkappsutil).
# Run it when the source has been patched since its stage was made (the stage date is the adpreclone date).
# A source whose stage is already at the PDB's code level (for example a DR copy staged after the last patch)
# does not need this step.
. "$(dirname "$0")/lib.sh"
need_user "$SRC_USER"
SENV="$SRC_BASE/EBSapps.env"
[ -r "$SENV" ] || die "no $SENV: run this on the source apps host"
# shellcheck disable=SC1090
. "$SENV" run >/dev/null 2>&1 || die "cannot load $SENV"
unset -f which 2>/dev/null
[ "$FILE_EDITION" = run ] || die "not on the run edition"
say "   source context $CONTEXT_NAME, run file system $RUN_BASE"
[ "$(basename "$RUN_BASE")" = fs2 ] || warn "run edition is $(basename "$RUN_BASE"), the other steps assume fs2: set them to copy that folder"

ask_secret AP "APPS password (source)"; ask_secret WP "WebLogic password (source)"
say "-- 1. adpreclone appsTier (about 5 minutes)"
printf '%s\n%s\n' "$AP" "$WP" | WATCH_STDIN=1 run_watched "$LOG_DIR/adpreclone_$(date +%H%M%S).log" \
  perl "$ADMIN_SCRIPTS_HOME/adpreclone.pl" appsTier || die "adpreclone failed"
unset AP WP
L=$(ls -t "$INST_TOP"/admin/log/clone/StageAppsTier_*.log 2>/dev/null | head -1)
# adpreclone ends with 'Completed Stage...' on screen; it never prints the ad*ctl 'exiting with status' line
check "adpreclone printed 'Completed Stage'" grep -q 'Completed Stage' "$(ls -t "$LOG_DIR"/adpreclone_*.log | head -1)"
[ -n "$L" ] && check "StageAppsTier log says Completed Successfully ($L)" grep -q 'Completed Successfully' "$L"
[ -n "$L" ] && check "no script in $L returned non-zero" bash -c "! grep -qE 'returning status [1-9]' '$L'"
check "stage moveplan refreshed today" bash -c "[ \$(stat -c %Y '$COMMON_TOP/clone/FMW/WLS/plan/moveplan.xml') -gt \$(( \$(date +%s) - 86400 )) ]"

say "-- 2. appsutil.zip for the database tier (25_db_register.sh takes it as its argument)"
perl "$AD_TOP/bin/admkappsutil.pl" >>"$LOG" 2>&1
check "appsutil.zip made" test -s "$INST_TOP/admin/out/appsutil.zip"
ls -l "$INST_TOP/admin/out/appsutil.zip" | tee -a "$LOG"
gate
ok "source stage ready. Next on the DB server: 20_db_prepare.sh, then 25_db_register.sh (it picks up this appsutil.zip)"
