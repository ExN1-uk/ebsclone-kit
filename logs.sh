#!/bin/bash
# logs.sh  -  watch the clone like `docker logs -f`. Ctrl-C only stops WATCHING; the job keeps running.
#
#   logs.sh            what is running now; follows the active step and its tool
#   logs.sh <step>     follow that step's newest log (and its tool), e.g. logs.sh 25_db_register
#   logs.sh ebs        follow the newest EBS tool logs on this server (adcfgclone / AutoConfig / txk)
#   logs.sh -l         list recent kit logs
#
# Works on both servers, as any user that can read /u01/ebsclone (root, oracle, applmgr).
VARS="${VARS:-/u01/ebsclone/clone.vars}"
[ -r "$VARS" ] || { echo "settings file $VARS not found" >&2; exit 2; }
. "$VARS"
RUN_DIR="$STATE_DIR/running"

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null; }

follow() {  # follow <file>...: Ctrl-C returns to the prompt, nothing else is touched
  local files=(); for f in "$@"; do [ -n "$f" ] && [ -e "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || { echo "no log files to follow"; exit 1; }
  echo "---- following ${#files[@]} log(s). Ctrl-C to stop watching (the job keeps running) ----"
  trap 'echo; echo "---- stopped watching. Still running: $(running_summary)"; exit 0' INT
  tail -n 40 -F "${files[@]}"
}

running_summary() {
  local s=""; for f in "$RUN_DIR"/*.step "$RUN_DIR"/*.tool; do
    [ -e "$f" ] || continue; alive "$(field "$f" pid)" && s="$s $(basename "$f")"; done
  echo "${s:- nothing}"
}

newest() { ls -t "$@" 2>/dev/null | head -1; }

ebs_logs() {  # newest EBS-owned logs on whichever server this is
  local out=()
  out+=("$(newest "$NEW_BASE"/fs2/inst/apps/*/admin/log/clone/*.log)")          # adcfgclone (VM)
  out+=("$(newest "$NEW_BASE"/fs2/inst/apps/*/admin/log/*/*.log)")              # AutoConfig (VM)
  out+=("$(newest "$LOG_DIR"/adcfgclone_*.log)")                                # adcfgclone screen (VM)
  out+=("$(newest "$DB_OH"/appsutil/log/"$DB_TAG"/*.log)")                      # txk / AutoConfig (DB)
  out+=("$(newest "$WORK_DIR"/txk_*.log "$WORK_DIR"/datapatch_*.log)")          # txk / datapatch screen (DB)
  printf '%s\n' "${out[@]}" | grep -v '^$'
}

case "${1:-}" in
  -l)
    ls -lt --time-style='+%F %T' "$LOG_DIR"/*.log 2>/dev/null | head -25 | awk '{print $6, $7, $8}'
    ;;
  ebs)
    mapfile -t F < <(ebs_logs); follow "${F[@]}"
    ;;
  "")
    files=()
    for f in "$RUN_DIR"/*.step "$RUN_DIR"/*.tool; do
      [ -e "$f" ] || continue
      p=$(field "$f" pid)
      if alive "$p"; then
        echo "RUNNING  $(basename "$f")  pid $p  since $(field "$f" started)  $(field "$f" cmd)"
        files+=("$(field "$f" log)")
      fi
    done
    if [ ${#files[@]} -eq 0 ]; then
      echo "Nothing from the kit is running. Newest logs:"; "$0" -l | head -5
      echo "Use: logs.sh <step> | logs.sh ebs"; exit 0
    fi
    follow "${files[@]}"
    ;;
  *)
    S="${1%.sh}"
    files=("$(newest "$LOG_DIR/${S}"_*.log)")
    [ -f "$RUN_DIR/$S.tool" ] && files+=("$(field "$RUN_DIR/$S.tool" log)")
    follow "${files[@]}"
    ;;
esac
