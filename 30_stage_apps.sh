#!/bin/bash
# 30_stage_apps.sh  -  new apps VM, as applmgr. Copies the pre-cloned apps files from the source host,
# checks the clone stage, and points the move plan at the NEW database (without this the new apps tier
# would connect to the source's database, which for a PROD-line source means PRODUCTION).
. "$(dirname "$0")/lib.sh"
need_user "$APPS_OWNER"
not_prod

if ! is_done copy; then
  say "-- 1. ssh access to $SRC_USER@$SRC_HOST"
  K="$HOME/.ssh/id_ebsclone_src"
  [ -f "$K" ] || ssh-keygen -q -t ed25519 -N "" -C "ebsclone-tmp-$(hostname -s)" -f "$K"
  # a temporary key for the copy: installed with ONE root password prompt, removed again by itself after the copy
  if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i "$K" "$SRC_USER@$SRC_HOST" true 2>/dev/null; then
    say "   one-time: the root password of $SRC_HOST, to put a temporary copy key on $SRC_USER there"
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$SRC_HOST" \
      "su - $SRC_USER -c 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'" < "$K.pub" \
      || die "could not install the copy key on $SRC_HOST (wrong root password?)"
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 -i "$K" "$SRC_USER@$SRC_HOST" true || die "still no key access to $SRC_USER@$SRC_HOST"
  fi
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
  SRCP=$(ssh -n -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST" "for d in $SRC_BASE/fs2/inst/apps/*/; do c=\$(basename \$d); [ -f \$d/appl/admin/\${c}_run.txt ] && echo \$d/appl/admin/\${c}_run.txt; done")
  [ "$(echo "$SRCP" | grep -c .)" -eq 1 ] || die "expected one <context>_run.txt pairs file on the source, found: ${SRCP:-none}"
  scp -q -i "$K" -o BatchMode=yes "$SRC_USER@$SRC_HOST:$SRCP" "$STATE_DIR/source_pairs.txt" || die "could not fetch $SRCP"
  ok "source pairs file saved as $STATE_DIR/source_pairs.txt"
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
  echo "no" > "$STATE_DIR/need_spoof"
elif [ "$ALLOW_RELEASE_SPOOF" = "yes" ]; then
  warn "stage has no OL8-aware check files: patch 33471111 is not on the source."
  warn "ALLOW_RELEASE_SPOOF=yes: 40 will set the release files to 7.9 for adcfgclone only and put them back."
  echo "yes" > "$STATE_DIR/need_spoof"
else
  die "the Oracle Linux 8 check files are missing. Unzip patch 33471111 on this VM and set PATCH_33471111_DIR to it, then rerun this step."
fi

say "-- 6. move plan: point the data sources at $SERVICE on $DB_SCAN"
P="$C/FMW/WLS/plan/moveplan.xml"
[ -f "$P.orig" ] || cp -p "$P" "$P.orig"
cp -p "$P.orig" "$P"
say "   before: $(grep -oE 'HOST=[^)]*|SERVICE_NAME=[^)]*' "$P" | sort -u | tr '\n' ' ')"
sed -i -E "s#HOST=${SRC_DB_HOST_RE}#HOST=${DB_SCAN}#g; s#SERVICE_NAME=${SRC_SERVICE}#SERVICE_NAME=${SERVICE}#g" "$P"
# the plan also names the source apps host (server listen addresses, machine): this VM instead
SRC_APP=$(sed -n 's/^s_atName=//p' "$STATE_DIR/source_pairs.txt")
[ -n "$SRC_APP" ] || die "no s_atName in $STATE_DIR/source_pairs.txt"
sed -i -E "s#>${SRC_APP}(\.${NET_DOMAIN})?<#>${APPS_HOST}\1<#g" "$P"
say "   apps host values: $(grep -oE "<value>${APPS_HOST}[^<]*</value>" "$P" | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
say "   after:  $(grep -oE 'HOST=[^)]*|SERVICE_NAME=[^)]*' "$P" | sort -u | tr '\n' ' ')"
N=$(grep -ciE "$LEAK_RE" "$P")
[ "$N" -eq 0 ] && ok "move plan has no source/PROD references" || { grep -niE "$LEAK_RE" "$P" | head -10 | tee -a "$LOG"; bad "$N source/PROD references left in the move plan"; }
check "every data source now names $SERVICE" bash -c "! grep -oE 'SERVICE_NAME=[^)]*' '$P' | grep -v 'SERVICE_NAME=$SERVICE' | grep -q ."
gate
ok "staged. Next: 40_configure_apps.sh"
