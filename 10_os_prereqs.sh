#!/bin/bash
# 10_os_prereqs.sh  -  new apps VM, as root. Installs the EBS 12.2 OS prerequisites (KA1007 / 1330701.1).
# Safe to rerun. Oracle's way: the oracle-ebs-server-R12-preinstall RPM.
. "$(dirname "$0")/lib.sh"
need_root
not_prod

say "-- 1. preinstall RPM"
if rpm -q oracle-ebs-server-R12-preinstall >/dev/null 2>&1; then
  ok "already installed: $(rpm -q oracle-ebs-server-R12-preinstall)"
elif ls "$RPM_DIR"/*.rpm >/dev/null 2>&1; then
  say "   installing from the offline copy in $RPM_DIR"
  dnf -y --disablerepo='*' install "$RPM_DIR"/*.rpm >>"$LOG" 2>&1 || die "offline install failed, see $LOG"
else
  say "   installing from the Oracle Linux 8 repositories (needs yum.oracle.com or a local mirror)"
  # Oracle ships the preinstall package in the Addons repository, which Oracle Linux 8 defines but leaves disabled
  ADDONS=""; dnf repolist --all 2>/dev/null | grep -q '^ol8_addons' && ADDONS="--enablerepo=ol8_addons"
  [ -n "$ADDONS" ] && say "   (switching on Oracle's ol8_addons repository for this install only)"
  dnf -y $ADDONS install oracle-ebs-server-R12-preinstall >>"$LOG" 2>&1 \
    || die "dnf could not install the preinstall RPM. Either give the VM repository access, or download it with its dependencies into $RPM_DIR and rerun."
fi
rpm -q oracle-ebs-server-R12-preinstall >/dev/null || die "preinstall RPM still missing"
ok "$(rpm -q oracle-ebs-server-R12-preinstall)"

say "-- 1b. tools the kit and EBS use (a minimal Oracle Linux 8 install has none of them)"
MISS=""; for p in tar unzip rsync; do rpm -q "$p" >/dev/null 2>&1 || MISS="$MISS $p"; done
if [ -n "$MISS" ]; then
  if ls "$RPM_DIR"/*.rpm >/dev/null 2>&1; then dnf -y --disablerepo='*' install "$RPM_DIR"/*.rpm >>"$LOG" 2>&1 || true
  else dnf -y install $MISS >>"$LOG" 2>&1 || true; fi
fi
for p in tar unzip rsync; do rpm -q "$p" >/dev/null 2>&1 && ok "$p installed" || die "$p is missing and could not be installed (repository access, or put it in $RPM_DIR)"; done

say "-- 2. the apps owner"
getent group "$APPS_GROUP" >/dev/null || groupadd -g 54321 "$APPS_GROUP"
getent group dba >/dev/null || groupadd -g 54322 dba
if id "$APPS_OWNER" >/dev/null 2>&1; then
  ok "$APPS_OWNER exists ($(id "$APPS_OWNER"))"
else
  # uid 54322 matches the PROD/DR applmgr, so a copied tree keeps sensible ownership
  useradd -u 54322 -g "$APPS_GROUP" -G dba -m -s /bin/bash "$APPS_OWNER" && ok "created $APPS_OWNER"
  say "   set a password for $APPS_OWNER yourself if people will log in as it (passwd $APPS_OWNER)"
fi

say "-- 3. limits for $APPS_OWNER (the preinstall RPM sets them for oracle only)"
cat > /etc/security/limits.d/99-ebs-${APPS_OWNER}.conf <<EOF
$APPS_OWNER soft nofile 65536
$APPS_OWNER hard nofile 65536
$APPS_OWNER soft nproc  16384
$APPS_OWNER hard nproc  16384
$APPS_OWNER soft stack  10240
$APPS_OWNER hard stack  32768
EOF
ok "/etc/security/limits.d/99-ebs-${APPS_OWNER}.conf"

say "-- 4. inventory and base folder"
if [ -e /etc/oraInst.loc ] && ! grep -q "^inventory_loc=$INV_LOC" /etc/oraInst.loc; then
  die "/etc/oraInst.loc already points elsewhere: $(cat /etc/oraInst.loc). Check before changing it."
fi
printf 'inventory_loc=%s\ninst_group=%s\n' "$INV_LOC" "$APPS_GROUP" > /etc/oraInst.loc
mkdir -p "$INV_LOC" "$NEW_BASE" "$STATE_DIR" "$LOG_DIR"
chown "$APPS_OWNER:$APPS_GROUP" "$INV_LOC" "$NEW_BASE"; chmod 775 "$INV_LOC"
# kit state and logs are shared by root and applmgr steps
chgrp -R "$APPS_GROUP" /u01/ebsclone && chmod 2775 /u01/ebsclone "$STATE_DIR" "$LOG_DIR" && chmod g+w "$LOG_DIR"/* "$STATE_DIR"/* 2>/dev/null
ok "/etc/oraInst.loc, $INV_LOC, $NEW_BASE"

say "-- 5. host entry (adcfgclone wants the node to resolve to itself)"
grep -qE "^$APPS_IP[[:space:]].*$APPS_HOST" /etc/hosts || echo "$APPS_IP $APPS_HOST.$NET_DOMAIN $APPS_HOST" >> /etc/hosts
ok "$(grep -E "^$APPS_IP[[:space:]]" /etc/hosts)"

say "-- 6. libXm.so.2 (Forms and Reports link against it; motif ships libXm.so.4)"
for d in /usr/lib /usr/lib64; do
  [ -e $d/libXm.so.2 ] || { [ -e $d/libXm.so.4 ] && ln -s $d/libXm.so.4 $d/libXm.so.2 && ok "linked $d/libXm.so.2 -> libXm.so.4"; }
done

say "-- 7. firewall (only if firewalld is running): open the web port"
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-port=${WEB_PORT}/tcp && firewall-cmd -q --reload && ok "opened ${WEB_PORT}/tcp"
else
  ok "firewalld not running, nothing to open"
fi

say "-- 8. time synchronisation (chronyd)"
if rpm -q chrony >/dev/null 2>&1; then
  systemctl enable --now chronyd >>"$LOG" 2>&1 && ok "chronyd enabled and started"
  sleep 20; timedatectl show -p NTPSynchronized --value | grep -qx yes && ok "clock synchronised" \
    || warn "chronyd runs but is not synchronised yet: check the servers in /etc/chrony.conf are reachable from this VM"
else
  warn "chrony not installed: dnf install chrony (or point the VM at your site's time source)"
fi

say "-- 9. verify"
bash "$(dirname "$0")/00_check_vm.sh"
