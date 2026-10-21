#!/bin/bash
# 30_stage_apps.sh  -  new apps VM, as root (it switches to applmgr by itself). Copies the pre-cloned apps files from the source host,
# checks the clone stage, and points the move plan at the NEW database (without this the new apps tier
# would connect to the source's database, which for a PROD-line source means PRODUCTION).
# Run it as root. The one question for the source's root password is asked here, while the step still has your
# terminal (after su to another user, ssh cannot reach the terminal and would answer its own prompt). Then the
# step carries on as the apps owner by itself.
if [ "$(id -u)" -eq 0 ]; then
  # shellcheck disable=SC1090
  . "${VARS:-/u01/ebsclone/clone.vars}"
  K="$(getent passwd "$APPS_OWNER" | cut -d: -f6)/.ssh/id_ebsclone_src"
  su - "$APPS_OWNER" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && { [ -f '$K' ] || ssh-keygen -q -t ed25519 -N '' -C ebsclone-tmp-\$(hostname -s) -f '$K'; }"
  if [ ! -e "$STATE_DIR/30_stage_apps.copy" ] && ! su - "$APPS_OWNER" -c \
       "ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i '$K' $SRC_USER@$SRC_HOST true" 2>/dev/null; then
    echo "One-time: a temporary copy key goes on the source; it removes itself after the copy."
    echo "The next prompt wants the root password of the SOURCE ($SRC_HOST), not of this VM."
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$SRC_HOST" \
      "su - $SRC_USER -c 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'" < "$K.pub" \
      || { echo "STOP: could not put the copy key on $SRC_HOST (wrong root password?). Run this step again."; exit 1; }
  fi
  exec su - "$APPS_OWNER" -c "$(readlink -f "$0") $*"
fi

. "$(dirname "$0")/lib.sh"
need_user "$APPS_OWNER"
not_prod

if ! is_done copy; then
  say "-- 1. ssh access to $SRC_USER@$SRC_HOST"
  K="$HOME/.ssh/id_ebsclone_src"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i "$K" "$SRC_USER@$SRC_HOST" true 2>/dev/null \
    || die "no key access to $SRC_USER@$SRC_HOST: run this step as root (/u01/ebsclone/kit/30_stage_apps.sh), it sets the key up"
  ok "key access to the source"

  say "-- 2. what the source holds"
  ssh -n -i "$K" "$SRC_USER@$SRC_HOST" "ls -ld --time-style=+%F $SRC_BASE/fs2/EBSapps/comn/clone/bin/adcfgclone.pl $SRC_BASE/fs2/EBSapps/comn/clone/FMW/WLS/plan/moveplan.xml; du -sh $SRC_BASE/fs2/EBSapps $SRC_BASE/fs_ne" | tee -a "$LOG" \
    || die "no clone stage under $SRC_BASE/fs2 on the source (run adpreclone.pl appsTier there first)"
  say "   the moveplan date above is when the source's clone stage was made (adpreclone)"

  say "-- 3. copy (about 65 GB). FMW_Home and inst are left out: adcfgclone builds them and refuses if they exist."
  say "   The folder must stay called fs2 (adcfgclone fails with RC-50004 if renamed)."
  run_watched "$LOG_DIR/rsync_$(date +%H%M%S).log" rsync -a --stats --no-inc-recursive \
    --exclude '/fs2/inst' --exclude '/fs2/FMW_Home' -e "ssh -i $K -o BatchMode=yes" \
    "$SRC_USER@$SRC_HOST:$SRC_BASE/fs2" "$SRC_USER@$SRC_HOST:$SRC_BASE/fs_ne" "$NEW_BASE/" || die "copy failed"
  # the source's own pairs file (in inst, which is not copied): 40 turns it into the answers for adcfgclone
  # a source that was itself cloned can hold other nodes' contexts too (a DR copy keeps PROD's): keep its own
  SRCP=$(ssh -n -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST" "for d in $SRC_BASE/fs2/inst/apps/*/; do c=\$(basename \$d); [ -f \$d/appl/admin/\${c}_run.txt ] && echo \$d/appl/admin/\${c}_run.txt; done")
  if [ "$(echo "$SRCP" | grep -c .)" -gt 1 ]; then
    SRCH=$(ssh -n -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST" "hostname -s" | tr '[:upper:]' '[:lower:]')
    say "   more than one pairs file on the source; using the one for its own host ($SRCH)"
    SRCP=$(echo "$SRCP" | grep -i "_${SRCH}_run.txt\$")
  fi
  [ "$(echo "$SRCP" | grep -c .)" -eq 1 ] || die "expected one <context>_run.txt pairs file on the source, found: ${SRCP:-none}"
  scp -q -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST:$SRCP" "$STATE_DIR/source_pairs.txt" || die "could not fetch $SRCP"
  ok "source pairs file saved as $STATE_DIR/source_pairs.txt"
  # its full context file sits next to it: it names every host and database the source talks to
  scp -q -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST:${SRCP%_run.txt}.xml" "$STATE_DIR/source_context.xml" \
    && ok "source context file saved as $STATE_DIR/source_context.xml" || warn "could not fetch ${SRCP%_run.txt}.xml: only the move plan and pairs file are read"
  done_mark copy
  # the copy key removes itself from the source, then is deleted here
  ssh -n -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST" "sed -i '/ebsclone-tmp-$(hostname -s)\$/d' ~/.ssh/authorized_keys" \
    && ok "temporary copy key removed from $SRC_HOST" || warn "could not remove the ebsclone-tmp key line from $SRC_USER@$SRC_HOST:~/.ssh/authorized_keys: remove it by hand"
  rm -f "$K" "$K.pub"
fi
check "source pairs file present" test -s "$STATE_DIR/source_pairs.txt"
du -sh "$NEW_BASE"/fs2 "$NEW_BASE"/fs_ne | tee -a "$LOG"

C="$NEW_BASE/fs2/EBSapps/comn/clone"
say "-- 4. clone stage checks"
check "adcfgclone.pl present" test -f "$C/bin/adcfgclone.pl"
check "move plan present" test -f "$C/FMW/WLS/plan/moveplan.xml"
check "no FMW_Home or inst copied" bash -c "[ ! -e '$NEW_BASE/fs2/FMW_Home' ] && [ ! -e '$NEW_BASE/fs2/inst' ]"

say "-- 5. OL8 prerequisite check files (patch 33471111, MOS KB332452)"
# adpreclone copies <FMW_Home>/webtier/inventory/Scripts/prereq into the stage; adcfgclone checks the OS
# against the stage copy. Oracle's fix replaces that folder with the one in patch 33471111 (then re-preclones).
# We put the patch's folder straight into OUR copy of the stage, which is what a re-preclone would produce,
# and leave the source untouched.
SP="$C/prereq/webtier/Scripts/prereq"
# OL8 is listed in linux64/refhost.xml as <VERSION VALUE="8"/> + <VENDOR VALUE="oracle"/> (the 'oracle-8.x'
# in Oracle's error text is the tool joining vendor and version; the string itself is not in the file)
knows_ol8() { grep -A4 '<VERSION VALUE="8"/>' "$1/linux64/refhost.xml" 2>/dev/null | grep -q '<VENDOR VALUE="oracle"/>'; }
if ! knows_ol8 "$SP" && [ -n "${PATCH_33471111_DIR:-}" ]; then
  NEWP=$(find "$PATCH_33471111_DIR" -type d -name prereq | head -1)
  [ -n "$NEWP" ] && [ -f "$NEWP/linux64/refhost.xml" ] || die "no prereq/linux64/refhost.xml inside $PATCH_33471111_DIR (unzip patch 33471111 there)"
  knows_ol8 "$NEWP" || die "$NEWP/linux64/refhost.xml has no Oracle Linux 8 entry: wrong patch?"
  [ -d "$SP.pre33471111" ] || cp -a "$SP" "$SP.pre33471111"
  rm -rf "$SP" && cp -a "$NEWP" "$SP"
  ok "stage check files replaced from patch 33471111 (original kept as $SP.pre33471111)"
fi
if knows_ol8 "$SP"; then
  ok "stage check files know Oracle Linux 8"
else
  die "the Oracle Linux 8 check files are missing. Unzip patch 33471111 on this VM and set PATCH_33471111_DIR to it, then rerun this step."
fi

say "-- 6. what the source points at, and the move plan pointed at this environment instead"
P="$C/FMW/WLS/plan/moveplan.xml"
[ -f "$P.orig" ] || cp -p "$P" "$P.orig"
cp -p "$P.orig" "$P"
# Everything the source's own configuration names is what the copy must never reach or keep: no list to type in.
harvest_source "$P.orig"
not_prod
LEAK_RE=$(source_leak_re)
say "   source databases: $(tr '\n' ' ' < "$STATE_DIR/source_db_hosts")"
say "   source services:  $(tr '\n' ' ' < "$STATE_DIR/source_services")"
say "   source hosts:     $(tr '\n' ' ' < "$STATE_DIR/source_app_hosts")"
say "   before: $(grep -oE 'HOST=[^)]*|SERVICE_NAME=[^)]*' "$P" | sort -u | tr '\n' ' ')"
# every data source goes to the new database
sed -i -E "s#HOST=[^)]*#HOST=${DB_SCAN}#g; s#SERVICE_NAME=[^)]*#SERVICE_NAME=${SERVICE}#g" "$P"
# every apps-side host in the plan (server listen addresses and machines, of every source node) becomes this VM.
# A source cloned from a multi-node system keeps its other nodes' managed servers: on this single VM they are
# created but never started (this node's context only enables its own), and now they name nothing outside it.
D=$(printf '%s' "$NET_DOMAIN" | sed 's/\./\\./g')
for h in $(grep -vE '^[0-9.]+$' "$STATE_DIR/source_app_hosts" | sed 's/\..*//' | sort -u); do
  sed -i -E "s#>${h}(\.${D})?<#>${APPS_HOST}\1<#gI; s#>${h}_#>${APPS_HOST}_#gI" "$P"
done
say "   apps host values: $(grep -oE "<value>${APPS_HOST}[^<]*</value>" "$P" | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
say "   after:  $(grep -oE 'HOST=[^)]*|SERVICE_NAME=[^)]*' "$P" | sort -u | tr '\n' ' ')"
N=$(grep -ciE "$LEAK_RE" "$P")
[ "$N" -eq 0 ] && ok "move plan names nothing of the source's" || { grep -niE "$LEAK_RE" "$P" | head -10 | tee -a "$LOG"; bad "$N source references left in the move plan"; }
check "every data source now names $SERVICE" bash -c "! grep -oE 'SERVICE_NAME=[^)]*' '$P' | grep -v 'SERVICE_NAME=$SERVICE' | grep -q ."
gate
ok "staged. Next: 40_configure_apps.sh"
