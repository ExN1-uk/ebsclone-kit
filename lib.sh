# ebsclone shared functions. Sourced by every step script; not run on its own.
set -u
umask 002   # root and applmgr steps share state/ and logs/ (setgid oinstall folders)
EBSCLONE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS="${VARS:-/u01/ebsclone/clone.vars}"
[ -r "$VARS" ] || { echo "settings file $VARS not found (copy clone.vars.example there and edit it)" >&2; exit 2; }
# shellcheck disable=SC1090
. "$VARS"
STEP="$(basename "$0" .sh)"
RUN_DIR="$STATE_DIR/running"
mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUN_DIR" 2>/dev/null || true
chmod g+w "$RUN_DIR" 2>/dev/null || true
LOG="$LOG_DIR/${STEP}_$(date +%Y%m%d_%H%M%S).log"
FAILS=0
# register this step so logs.sh can find it; removed when the step ends
printf 'pid=%s\nlog=%s\nstarted=%s\nuser=%s\n' "$$" "$LOG" "$(date '+%F %T')" "$(id -un)" > "$RUN_DIR/$STEP.step" 2>/dev/null || true
EXIT_HOOKS=""
on_exit() { EXIT_HOOKS="$EXIT_HOOKS $1"; }   # steps add their own clean-up here; never set trap EXIT directly
_at_exit() { for h in $EXIT_HOOKS; do "$h"; done; rm -f "$RUN_DIR/$STEP.step"; }
trap _at_exit EXIT

_ts()  { date '+%H:%M:%S'; }
say()  { echo "[$(_ts)] $*" | tee -a "$LOG"; }
ok()   { echo "[$(_ts)]   OK    $*" | tee -a "$LOG"; }
bad()  { echo "[$(_ts)]   FAIL  $*" | tee -a "$LOG"; FAILS=$((FAILS+1)); }
warn() { echo "[$(_ts)]   WARN  $*" | tee -a "$LOG"; }
die()  { echo "[$(_ts)] STOP: $*" | tee -a "$LOG" >&2; exit 1; }

# check "description" command...   -> OK/FAIL line, never stops
check() { local d="$1"; shift; if "$@" >>"$LOG" 2>&1; then ok "$d"; else bad "$d"; fi; }
# gate: stop the step if any check failed
gate()  { [ "$FAILS" -eq 0 ] || die "$FAILS check(s) failed, see $LOG. Fix and rerun this step."; ok "all checks passed"; }

need_user() { [ "$(id -un)" = "$1" ] || die "run this step as $1 (you are $(id -un))"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run this step as root"; }

# step markers: a finished sub-step is skipped on rerun
done_mark() { touch "$STATE_DIR/${STEP}.$1"; }
is_done()   { [ -e "$STATE_DIR/${STEP}.$1" ]; }

confirm() {  # confirm "question" -> returns 0 only on an explicit yes
  local a; read -r -p "$1 Type yes to continue: " a; [ "$a" = "yes" ]
}

# read a password without echo, into the named variable
ask_secret() { local __v; read -rs -p "$2: " __v; echo; printf -v "$1" '%s' "$__v"; }

# The copy must never BE what it was copied from. 30_stage_apps.sh records every database, host and service the
# source's own configuration names (state/source_*); a step that finds the new database or this VM among them stops.
# Nobody has to list production by hand: whatever the source points at is, by definition, what the copy must not.
not_prod() {
  local n f
  [ "${#PDB}" -le 8 ] || die "PDB name $PDB is ${#PDB} characters: E-Business Suite keeps the database name in an 8-character column (FND_DATABASES.DB_NAME), so registration would fail. Use a PDB named with 8 characters or fewer."
  for f in source_db_hosts source_app_hosts; do
    [ -s "$STATE_DIR/$f" ] || continue
    for n in "$DB_SCAN" "$DB_HOST.$NET_DOMAIN" "$DB_IP" "$APPS_HOST.$NET_DOMAIN" "$APPS_IP"; do
      grep -qix "$n" "$STATE_DIR/$f" && die "$n is a host the source itself uses: the copy would point at the source. This kit only builds copies."
    done
  done
  if [ -s "$STATE_DIR/source_services" ] && grep -qix "$SERVICE" "$STATE_DIR/source_services"; then
    die "service $SERVICE is the source's own database service: the copy would point at the source."
  fi
  return 0
}

# harvest_source <move plan as copied>: every database, host and service the source's own configuration names
# (move plan, pairs file, context file), written to state/source_db_hosts, source_app_hosts, source_services and
# source_leak_re. 30 points the copy away from all of them, 40 blocks them and checks none survive.
harvest_source() {
  local P0="$1" SP="$STATE_DIR/source_pairs.txt" SX="$STATE_DIR/source_context.xml" d k
  d=$(printf '%s' "$NET_DOMAIN" | sed 's/\./\\./g')
  fq() { case "$1" in *.*) echo "$1";; ?*) echo "$1.$NET_DOMAIN";; esac; }
  { grep -ohE 'HOST=[^)]*' "$P0" "$SX" 2>/dev/null | cut -d= -f2 | tr -d ' '
    fq "$(sed -n 's/^s_dbhost=//p' "$SP")"
  } | tr '[:upper:]' '[:lower:]' | grep . | sort -u > "$STATE_DIR/source_db_hosts"
  grep -ohE 'SERVICE_NAME=[^)]*' "$P0" "$SX" 2>/dev/null | cut -d= -f2 | tr -d ' ' | grep . | sort -u > "$STATE_DIR/source_services"
  { echo "$SRC_HOST"
    for k in s_atName s_admhost s_webentryhost s_smtphost; do fq "$(sed -n "s/^$k=//p" "$SP")"; done
    grep -ohiE "\b[a-z0-9][a-z0-9-]*\.$d\b" "$P0" "$SP" "$SX" 2>/dev/null
    # literal addresses, only on the networks of the servers involved (version numbers look like addresses too)
    grep -ohE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$P0" "$SX" 2>/dev/null \
      | grep -E "^($( { echo "$SRC_HOST"; getent ahostsv4 "$SRC_HOST" | awk '{print $1}'; echo "$DB_IP"; echo "$APPS_IP"; } \
          | grep -oE '^[0-9]+\.[0-9]+\.' | sort -u | sed 's/\./\\./g' | paste -sd'|'))"
  } | tr '[:upper:]' '[:lower:]' | grep . | sort -u | grep -vxFf "$STATE_DIR/source_db_hosts" > "$STATE_DIR/source_app_hosts"
  { sed 's/\..*//' "$STATE_DIR/source_db_hosts" "$STATE_DIR/source_app_hosts"
    cat "$STATE_DIR/source_services"
    for k in s_dbSid s_dbGlnam s_contextname; do sed -n "s/^$k=//p" "$SP"; done
  } | grep -E '^[A-Za-z][A-Za-z0-9_-]{2,}$' | sort -u | paste -sd'|' > "$STATE_DIR/source_leak_re"
}
source_leak_re() {
  local r; r=$(cat "$STATE_DIR/source_leak_re" 2>/dev/null)
  [ -n "$r" ] || die "no record of the source's names (state/source_leak_re): rerun 30_stage_apps.sh"
  echo "$r"
}

# pdb_in_use: the machines that have user sessions in the PDB right now, other than this database server
pdb_in_use() {
  sys_sql <<SQL | grep -v '^[[:space:]]*$'
set heading off feedback off pages 0 lines 200
select distinct s.machine from v\$session s join v\$pdbs p on p.con_id=s.con_id
 where p.name='${PDB}' and s.type='USER' and lower(s.machine) not like lower('$(hostname -s)%');
SQL
}

# run_watched <logfile> <command...>
# Runs the command detached (survives Ctrl-C, a closed window or a VPN drop), follows its log, and stops
# it if it stalls: log not growing for STALL_MINUTES AND the last line looks like a prompt.
#   WATCH_STDIN=1 run_watched ...  passes this function's stdin to the command (used to feed passwords
#   through a pipe); otherwise the command gets /dev/null and must not prompt.
# If this step's tool is STILL RUNNING from an earlier attempt, it reattaches instead of starting it again.
# Watch it from any other session with logs.sh.
run_watched() {
  local L="$1"; shift
  local W="$RUN_DIR/$STEP.tool" pid=""
  if [ -f "$W" ]; then
    pid=$(sed -n 's/^pid=//p' "$W"); local oldlog; oldlog=$(sed -n 's/^log=//p' "$W")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      L="$oldlog"; say "REATTACHING to the tool still running from an earlier attempt (pid $pid, log $L)"
    else
      pid=""
    fi
  fi
  if [ -z "$pid" ]; then
    say "running: $* (log $L)"
    rm -f "$L.rc"
    # the wrapper records the exit code, so a reattached session can still read it
    if [ "${WATCH_STDIN:-0}" = 1 ]; then
      exec 3<&0; setsid nohup bash -c '"$@"; echo $? > "$0.rc"' "$L" "$@" >"$L" 2>&1 <&3 & exec 3<&-
    else
      setsid nohup bash -c '"$@"; echo $? > "$0.rc"' "$L" "$@" >"$L" 2>&1 </dev/null &
    fi
    pid=$!
    printf 'pid=%s\nlog=%s\nstarted=%s\ncmd=%s\n' "$pid" "$L" "$(date '+%F %T')" "$*" > "$W"
    say "   follow it from another window: $EBSCLONE_HOME/logs.sh $STEP   (Ctrl-C there does not stop it)"
  fi
  local last=0 still=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    local sz; sz=$(stat -c %s "$L" 2>/dev/null || echo 0)
    if [ "$sz" -eq "$last" ]; then still=$((still+30)); else still=0; last=$sz; fi
    if [ "$still" -ge $((STALL_MINUTES*60)) ] && tail -c 300 "$L" | tail -1 | grep -qE '[]?:] *$'; then
      warn "no output for ${STALL_MINUTES} min and the last line is a prompt: $(tail -1 "$L")"
      # setsid gave the tool its own process group: kill all of it, so no java child is left behind
      kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
      die "stalled waiting for input. Check the prompt above, fix the answers, rerun."
    fi
  done
  local rc; rc=$(cat "$L.rc" 2>/dev/null || echo 1)
  rm -f "$W"
  say "finished rc=$rc"; return "$rc"
}

# sqlplus as sysdba in the CDB root (DB server, oracle)
sys_sql() { "$DB_OH/bin/sqlplus" -s / as sysdba; }
db_env()  { export ORACLE_HOME="$DB_OH" ORACLE_SID="$CDB_SID" PATH="$DB_OH/bin:$PATH"; }
# apps_login_ok <password> <connect string>: true if APPS can log in. Password goes on stdin, not argv.
apps_login_ok() {
  printf 'connect apps/"%s"@%s\nselect 7*6 from dual;\nexit\n' "$1" "$2" | sqlplus -s -L /nolog 2>&1 | grep -qE '^[[:space:]]*42$'
}

say "== $STEP  (settings $VARS, log $LOG)"
