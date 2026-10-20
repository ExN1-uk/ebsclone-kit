#!/bin/bash
# 00_check_vm.sh  -  new apps VM, as root. Read-only: changes nothing.
# Run before 10 (expect the package lines to fail on a bare VM) and again after 10 (everything must pass).
. "$(dirname "$0")/lib.sh"
need_root
not_prod

say "-- operating system"
REL=$(cat /etc/oracle-release 2>/dev/null || cat /etc/redhat-release)
say "   release: $REL"
check "Oracle Linux / RHEL 8.2 or later" bash -c "echo '$REL' | grep -qE 'release 8\.([2-9]|[1-9][0-9])'"
check "release files are genuine" bash -c "! ls /etc/*release.ebsbak 2>/dev/null | grep -q ."
check "x86_64" test "$(uname -m)" = x86_64

say "-- name and network"
FQDN=$(hostname -f 2>/dev/null || hostname)
say "   hostname -f: $FQDN"
check "hostname is $APPS_HOST" bash -c "[ \"\$(hostname -s)\" = '$APPS_HOST' ]"
check "FQDN is 30 characters or less (EBS limit)" test "${#FQDN}" -le 30
check "own name resolves to $APPS_IP" bash -c "getent ahostsv4 $APPS_HOST.$NET_DOMAIN | grep -qw '$APPS_IP'"
check "DB host $DB_HOST.$NET_DOMAIN resolves" getent hosts "$DB_HOST.$NET_DOMAIN"
check "DB scan $DB_SCAN resolves" getent hosts "$DB_SCAN"
check "DB listener $DB_SCAN:$DB_PORT reachable" timeout 5 bash -c "</dev/tcp/$DB_SCAN/$DB_PORT"
check "source apps host $SRC_HOST:22 reachable" timeout 5 bash -c "</dev/tcp/$SRC_HOST/22"
# not a hard stop (adcfgclone does not check it), but concurrent manager and WebLogic times drift without it
timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes && ok "time is synchronised" \
  || warn "clock not NTP-synchronised (chronyd: $(systemctl is-active chronyd 2>/dev/null)): 10 enables chronyd; it needs a reachable time server"

say "-- capacity"
U01_FREE=$(df --output=avail --block-size=1G /u01 2>/dev/null | tail -1 | tr -d ' ')
say "   /u01 free: ${U01_FREE:-none} GB"
check "/u01 exists with at least 150 GB free (copy ~65 GB + FMW build + logs)" test "${U01_FREE:-0}" -ge 150
MEM=$(free -g | awk '/^Mem/{print $2}'); say "   memory: ${MEM} GB"
check "at least 12 GB RAM (one running apps tier uses ~6 GB)" test "$MEM" -ge 12
check "swap configured" bash -c "[ \$(free -g | awk '/^Swap/{print \$2}') -ge 4 ]"
check "/tmp has 5 GB free" bash -c "[ \$(df --output=avail --block-size=1G /tmp | tail -1 | tr -d ' ') -ge 5 ]"
check "web port $WEB_PORT is free" bash -c "! ss -ltn | grep -q ':$WEB_PORT '"

say "-- EBS prerequisites (fail on a bare VM until 10_os_prereqs.sh has run)"
check "oracle-ebs-server-R12-preinstall installed" rpm -q oracle-ebs-server-R12-preinstall
# KA1007 (1330701.1) section 2.3, Oracle Linux 8 application tier list, plus ksh and libcap (patch 33471111 refhost)
# and tar, unzip, rsync (the kit copies and unpacks with them; a minimal install has none)
PKGS="binutils gcc gcc-c++ gdbm.i686 gdbm.x86_64 glibc.i686 glibc.x86_64 glibc-common glibc-devel.i686 glibc-devel.x86_64
libaio.i686 libaio.x86_64 libaio-devel libgcc.i686 libgcc.x86_64 libgomp libnsl.i686 libnsl.x86_64
libstdc++.i686 libstdc++.x86_64 libstdc++-devel.i686 libstdc++-devel.x86_64 libXi.i686 libXp.i686 libXp.x86_64 libXtst.i686
make perl-File-CheckTree redhat-lsb sysstat util-linux libXrender.i686 motif.i686 motif-devel.i686
ksh libcap tar unzip rsync"
MISSING=""; for p in $PKGS; do rpm -q "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
[ -z "$MISSING" ] && ok "all KA1007 OL8 packages present" || bad "missing packages:$MISSING"
check "user $APPS_OWNER exists in group $APPS_GROUP" bash -c "id -nG $APPS_OWNER | grep -qw $APPS_GROUP"
check "/etc/oraInst.loc points at $INV_LOC" grep -q "^inventory_loc=$INV_LOC" /etc/oraInst.loc
check "$NEW_BASE does not exist yet (or is empty)" bash -c "[ ! -e '$NEW_BASE' ] || [ -z \"\$(ls -A '$NEW_BASE')\" ]"
# the preinstall RPM sets soft 4096 / hard 65536 (Oracle's values); the EBS scripts raise the soft limit themselves
check "$APPS_OWNER open files hard limit >= 65536" bash -c "[ \$(su - $APPS_OWNER -c 'ulimit -Hn') -ge 65536 ]"
check "$APPS_OWNER processes limit >= 16384" bash -c "[ \$(su - $APPS_OWNER -c 'ulimit -u') = unlimited ] || [ \$(su - $APPS_OWNER -c 'ulimit -u') -ge 16384 ]"
check "libXm.so.2 available (Forms/Reports relink)" bash -c "ls /usr/lib/libXm.so.2 /usr/lib64/libXm.so.2 >/dev/null 2>&1"

say "-- informational"
say "   SELinux: $(getenforce 2>/dev/null)   firewalld: $(systemctl is-active firewalld 2>/dev/null)"
say "   CPUs: $(nproc)"
gate
