#!/usr/bin/env bash

# Start, stop, or restart the Paperclip development service for this checkout.
#
# Usage:
#   ./control.sh start
#   ./control.sh stop
#   ./control.sh restart
#   ./control.sh status

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
STATE_DIR="$REPO_ROOT/.paperclip"
LOG_FILE="$STATE_DIR/control.log"
PID_FILE="$STATE_DIR/control.pid"
LOCK_DIR="$STATE_DIR/control.lock"
DEFAULT_PORT="${PORT:-3100}"
STOP_TIMEOUT_SECONDS="${PAPERCLIP_CONTROL_STOP_TIMEOUT:-20}"
EXPECTED_PNPM_VERSION="9.15.4"
PNPM_BIN=""

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_DIM=$'\033[2m'
  COLOR_BLUE=$'\033[34m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_RED=$'\033[31m'
  COLOR_CYAN=$'\033[36m'
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_DIM=""
  COLOR_BLUE=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_RED=""
  COLOR_CYAN=""
fi

CONTROL_LABEL="${COLOR_BOLD}${COLOR_CYAN}Paperclip${COLOR_RESET}${COLOR_DIM} control${COLOR_RESET}"

print_status() {
  local color="$1"
  local label="$2"
  shift 2
  printf '%b %b%-7s%b %s\n' "$CONTROL_LABEL" "$color" "$label" "$COLOR_RESET" "$*"
}

colored_text() {
  local color="$1"
  local text="$2"
  printf '%b%s%b' "${COLOR_BOLD}${color}" "$text" "$COLOR_RESET"
}

green_text() {
  colored_text "$COLOR_GREEN" "$1"
}

yellow_text() {
  colored_text "$COLOR_YELLOW" "$1"
}

blue_text() {
  colored_text "$COLOR_BLUE" "$1"
}

red_text() {
  colored_text "$COLOR_RED" "$1"
}

info() {
  print_status "$COLOR_BLUE" "info" "$*"
}

success() {
  print_status "$COLOR_GREEN" "ok" "$*"
}

step() {
  print_status "$COLOR_CYAN" "run" "$*"
}

warn() {
  print_status "$COLOR_YELLOW" "warn" "$*" >&2
}

die() {
  print_status "$COLOR_RED" "error" "$*" >&2
  exit 1
}

usage() {
  printf '%b\n' "${COLOR_BOLD}Paperclip development service control${COLOR_RESET}"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Usage:${COLOR_RESET} ./control.sh <start|stop|restart|status>"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Commands:${COLOR_RESET}"
  printf '  %b%-8s%b %s\n' "$COLOR_GREEN" "start" "$COLOR_RESET" "Clean stale state and start Paperclip in the background"
  printf '  %b%-8s%b %s\n' "$COLOR_YELLOW" "stop" "$COLOR_RESET" "Gracefully stop this checkout and clean remaining owned processes"
  printf '  %b%-8s%b %s\n' "$COLOR_CYAN" "restart" "$COLOR_RESET" "Stop completely, then perform a clean start"
  printf '  %b%-8s%b %s\n' "$COLOR_BLUE" "status" "$COLOR_RESET" "Show the current Paperclip service state"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Environment:${COLOR_RESET}"
  printf '  %-42s %s\n' "PORT=<port>" "Server port (default: 3100)"
  printf '  %-42s %s\n' "PAPERCLIP_CONTROL_STOP_TIMEOUT=<secs>" "Shutdown timeout (default: 20)"
  printf '  %-42s %s\n' "NO_COLOR=1" "Disable colored output"
}

print_summary_row() {
  local label="$1"
  local value="$2"
  printf '  %b%-9s%b %s\n' "$COLOR_DIM" "$label" "$COLOR_RESET" "$value"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_pid_running() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

command_for_pid() {
  ps -o command= -p "$1" 2>/dev/null || true
}

pid_belongs_to_repo() {
  local pid="$1"
  local command
  command="$(command_for_pid "$pid")"
  [[ -n "$command" && "$command" == *"$REPO_ROOT"* ]]
}

wait_for_pid_exit() {
  local pid="$1"
  local timeout="$2"
  local elapsed=0
  while is_pid_running "$pid"; do
    if (( elapsed >= timeout * 10 )); then
      return 1
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  return 0
}

read_pid_file() {
  local value=""
  if [[ -f "$PID_FILE" ]]; then
    value="$(head -n 1 "$PID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$value"
  fi
}

health_url() {
  printf 'http://127.0.0.1:%s/api/health\n' "$DEFAULT_PORT"
}

health_is_ready() {
  local response
  response="$(curl --silent --show-error --max-time 2 "$(health_url)" 2>/dev/null || true)"
  [[ "$response" == *'"status":"ok"'* ]]
}

health_response() {
  curl --silent --show-error --max-time 2 "$(health_url)" 2>/dev/null || true
}

port_listener_pid() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  lsof -nP -tiTCP:"$DEFAULT_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

pnpm_version() {
  "$1" --version 2>/dev/null | head -n 1 || true
}

resolve_pnpm() {
  local candidate version candidate_list
  candidate_list="$(type -aP pnpm 2>/dev/null || true)"

  while IFS= read -r candidate; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    version="$(pnpm_version "$candidate")"
    if [[ "$version" == "$EXPECTED_PNPM_VERSION" ]]; then
      PNPM_BIN="$candidate"
      export PATH="$(dirname "$candidate"):$PATH"
      return 0
    fi
  done <<EOF
$candidate_list
EOF

  if command -v corepack >/dev/null 2>&1; then
    corepack prepare "pnpm@$EXPECTED_PNPM_VERSION" --activate >/dev/null 2>&1 || true
    candidate_list="$(type -aP pnpm 2>/dev/null || true)"
    while IFS= read -r candidate; do
      [[ -n "$candidate" && -x "$candidate" ]] || continue
      version="$(pnpm_version "$candidate")"
      if [[ "$version" == "$EXPECTED_PNPM_VERSION" ]]; then
        PNPM_BIN="$candidate"
        export PATH="$(dirname "$candidate"):$PATH"
        return 0
      fi
    done <<EOF
$candidate_list
EOF
  fi

  die "pnpm $EXPECTED_PNPM_VERSION is required. Run: corepack enable && corepack prepare pnpm@$EXPECTED_PNPM_VERSION --activate"
}

ensure_prerequisites() {
  local node_major
  command -v node >/dev/null 2>&1 || die "Node.js is not installed"
  command -v curl >/dev/null 2>&1 || die "curl is required for health checks"
  node_major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true)"
  [[ "$node_major" =~ ^[0-9]+$ ]] || die "Unable to determine the Node.js version"
  (( node_major >= 20 )) || die "Node.js 20 or newer is required (found $(node --version))"
  is_positive_integer "$DEFAULT_PORT" || die "PORT must be a positive integer (found: $DEFAULT_PORT)"
  is_positive_integer "$STOP_TIMEOUT_SECONDS" || die "PAPERCLIP_CONTROL_STOP_TIMEOUT must be a positive integer"
  resolve_pnpm
  [[ -f "$REPO_ROOT/package.json" ]] || die "Repository package.json not found at $REPO_ROOT"
}

ensure_start_prerequisites() {
  [[ -x "$REPO_ROOT/server/node_modules/.bin/tsx" ]] \
    || die "Dependencies are missing. Run: cd '$REPO_ROOT' && $PNPM_BIN install"
}

acquire_lock() {
  local owner=""
  mkdir -p "$STATE_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    return 0
  fi

  owner="$(head -n 1 "$LOCK_DIR/pid" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$owner" ]] && is_pid_running "$owner"; then
    die "Another control operation is active (pid $owner)"
  fi

  warn "Removing stale control lock"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || die "Unable to acquire control lock"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

repo_process_pids() {
  ps -axo pid=,command= 2>/dev/null \
    | awk -v root="$REPO_ROOT" '
        index($0, root) &&
        ($0 ~ /dev-runner\.ts/ || $0 ~ /dev-watch\.ts/ || $0 ~ /server\/src\/index\.ts/ || $0 ~ /tsx.*src\/index\.ts/ || $0 ~ /@paperclipai\/server/) {
          print $1
        }
      ' \
    | sort -u
}

process_group_belongs_to_repo() {
  local pgid="$1"
  ps -axo pgid=,command= 2>/dev/null \
    | awk -v group="$pgid" -v root="$REPO_ROOT" '
        $1 == group && index($0, root) { found = 1 }
        END { exit(found ? 0 : 1) }
      '
}

terminate_launcher_process_group() {
  local pgid="$1"
  [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 0
  process_group_belongs_to_repo "$pgid" || return 0

  step "Stopping detached process group $pgid"
  kill -TERM "-$pgid" 2>/dev/null || true
  local deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! process_group_belongs_to_repo "$pgid"; then
      return 0
    fi
    sleep 0.2
  done

  if process_group_belongs_to_repo "$pgid"; then
    warn "Process group $pgid did not stop gracefully; sending SIGKILL"
    kill -KILL "-$pgid" 2>/dev/null || true
  fi
}

terminate_repo_processes() {
  local pids pid remaining="" deadline
  pids="$(repo_process_pids || true)"
  [[ -n "$pids" ]] || return 0

  step "Stopping remaining processes owned by this checkout"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if is_pid_running "$pid" && pid_belongs_to_repo "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done <<EOF
$pids
EOF

  deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    remaining="$(repo_process_pids || true)"
    [[ -z "$remaining" ]] && return 0
    sleep 0.2
  done

  remaining="$(repo_process_pids || true)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if is_pid_running "$pid" && pid_belongs_to_repo "$pid"; then
      warn "Process $pid did not stop gracefully; sending SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done <<EOF
$remaining
EOF
}

stop_embedded_postgres_if_orphaned() {
  local pid_file="$HOME/.paperclip/instances/default/db/postmaster.pid"
  local pid command
  [[ -f "$pid_file" ]] || return 0
  pid="$(head -n 1 "$pid_file" 2>/dev/null | tr -d '[:space:]' || true)"
  is_pid_running "$pid" || return 0
  command="$(command_for_pid "$pid")"
  [[ "$command" == *postgres* && "$command" == *"$HOME/.paperclip/instances/default/db"* ]] || return 0

  # Never stop a database while a live Paperclip process from this checkout remains.
  [[ -z "$(repo_process_pids || true)" ]] || return 0
  warn "Stopping orphaned embedded PostgreSQL process $pid"
  kill -TERM "$pid" 2>/dev/null || true
  if ! wait_for_pid_exit "$pid" "$STOP_TIMEOUT_SECONDS"; then
    warn "Embedded PostgreSQL $pid did not stop gracefully; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

clean_transient_state() {
  rm -f \
    "$PID_FILE" \
    "$STATE_DIR/dev-server-status.json" \
    "$STATE_DIR/dev-server-restart-request.json"
}

stop_service() {
  local managed_stop_failed=0 launcher_pid listener had_owned_state=0

  step "$(yellow_text "Stopping") Paperclip"
  print_summary_row "Repo" "$REPO_ROOT"
  mkdir -p "$STATE_DIR"
  launcher_pid="$(read_pid_file || true)"
  if [[ -n "$(repo_process_pids || true)" ]]; then
    had_owned_state=1
  elif [[ -n "$launcher_pid" ]] && is_pid_running "$launcher_pid" && pid_belongs_to_repo "$launcher_pid"; then
    had_owned_state=1
  fi

  if [[ -x "$REPO_ROOT/server/node_modules/.bin/tsx" ]] \
    && (cd "$REPO_ROOT" && "$PNPM_BIN" dev:stop >>"$LOG_FILE" 2>&1); then
    :
  else
    managed_stop_failed=1
    warn "Registered-service shutdown failed; continuing with scoped process cleanup"
    print_summary_row "Details" "$LOG_FILE"
  fi

  if [[ -n "$launcher_pid" ]] && is_pid_running "$launcher_pid" && pid_belongs_to_repo "$launcher_pid"; then
    kill -TERM "$launcher_pid" 2>/dev/null || true
    wait_for_pid_exit "$launcher_pid" "$STOP_TIMEOUT_SECONDS" || true
  fi

  terminate_launcher_process_group "$launcher_pid"
  terminate_repo_processes
  if (( had_owned_state )); then
    stop_embedded_postgres_if_orphaned
  fi
  clean_transient_state

  listener="$(port_listener_pid)"
  if [[ -n "$listener" ]] && pid_belongs_to_repo "$listener"; then
    die "Paperclip process $listener still owns port $DEFAULT_PORT after cleanup"
  fi
  if health_is_ready; then
    die "A Paperclip health endpoint is still active at $(health_url)"
  fi

  if (( managed_stop_failed )); then
    success "$(green_text "Stop succeeded"); Paperclip stopped using fallback cleanup"
  else
    success "$(green_text "Stop succeeded"); Paperclip stopped cleanly"
  fi
}

start_service() {
  local listener launcher_pid

  ensure_start_prerequisites

  # start is deliberately clean and idempotent: replace any existing instance.
  if health_is_ready || [[ -n "$(repo_process_pids || true)" ]] || [[ -n "$(read_pid_file || true)" ]]; then
    info "Existing or stale instance detected; cleaning it first"
    stop_service
  else
    clean_transient_state
  fi

  listener="$(port_listener_pid)"
  if [[ -n "$listener" ]]; then
    if pid_belongs_to_repo "$listener"; then
      warn "Cleaning stale repository process $listener on port $DEFAULT_PORT"
      kill -TERM "$listener" 2>/dev/null || true
      wait_for_pid_exit "$listener" "$STOP_TIMEOUT_SECONDS" || kill -KILL "$listener" 2>/dev/null || true
    else
      die "Port $DEFAULT_PORT is occupied by another process (pid $listener); refusing to kill it"
    fi
  fi

  mkdir -p "$STATE_DIR"
  : > "$LOG_FILE" || die "Cannot write log file: $LOG_FILE"
  step "$(blue_text "Starting") Paperclip"
  print_summary_row "Port" "$DEFAULT_PORT"
  print_summary_row "Repo" "$REPO_ROOT"
  launcher_pid="$(
    PAPERCLIP_CONTROL_PNPM="$PNPM_BIN" \
    PAPERCLIP_CONTROL_ROOT="$REPO_ROOT" \
    PAPERCLIP_CONTROL_LOG="$LOG_FILE" \
    PAPERCLIP_CONTROL_PORT="$DEFAULT_PORT" \
    node -e '
      const fs = require("node:fs");
      const { spawn } = require("node:child_process");
      const pnpm = process.env.PAPERCLIP_CONTROL_PNPM;
      const root = process.env.PAPERCLIP_CONTROL_ROOT;
      const log = process.env.PAPERCLIP_CONTROL_LOG;
      const port = process.env.PAPERCLIP_CONTROL_PORT;
      const fd = fs.openSync(log, "a");
      const child = spawn(pnpm, ["dev"], {
        cwd: root,
        detached: true,
        stdio: ["ignore", fd, fd],
        env: {
          ...process.env,
          PORT: port,
          PATH: `${require("node:path").dirname(pnpm)}:${process.env.PATH ?? ""}`,
        },
      });
      child.on("error", (error) => {
        process.stderr.write(`${error.stack ?? error.message}\n`);
        process.exit(1);
      });
      child.unref();
      fs.closeSync(fd);
      process.stdout.write(String(child.pid));
    '
  )" || die "Failed to launch Paperclip"
  [[ "$launcher_pid" =~ ^[1-9][0-9]*$ ]] || die "Launcher returned an invalid PID: $launcher_pid"
  printf '%s\n' "$launcher_pid" > "$PID_FILE" || die "Cannot write PID file: $PID_FILE"

  launcher_pid="$(read_pid_file || true)"
  success "$(green_text "Start succeeded"); Paperclip is $(blue_text "starting") in the background"
  print_summary_row "PID" "$launcher_pid"
  print_summary_row "URL" "${COLOR_BOLD}http://127.0.0.1:$DEFAULT_PORT${COLOR_RESET}"
  print_summary_row "Health" "$(health_url)"
  print_summary_row "Log" "$LOG_FILE"
}

status_service() {
  local launcher_pid listener response repo_pids status_label

  launcher_pid="$(read_pid_file || true)"
  listener="$(port_listener_pid)"
  repo_pids="$(repo_process_pids || true)"
  response="$(health_response)"

  if [[ "$response" == *'"status":"ok"'* ]]; then
    success "Paperclip is $(green_text "running")"
    status_label="$(green_text "healthy")"
  elif [[ -n "$listener" ]]; then
    warn "Port $DEFAULT_PORT is listening, but health check is not ready"
    status_label="$(yellow_text "starting or unhealthy")"
  elif [[ -n "$repo_pids" ]] || [[ -n "$launcher_pid" ]]; then
    warn "Paperclip processes or state files exist, but no health endpoint is reachable"
    status_label="$(yellow_text "stale or stopped")"
  else
    info "Paperclip is $(red_text "stopped")"
    status_label="$(red_text "stopped")"
  fi

  print_summary_row "Status" "$status_label"
  print_summary_row "Repo" "$REPO_ROOT"
  print_summary_row "Port" "$DEFAULT_PORT"
  print_summary_row "URL" "${COLOR_BOLD}http://127.0.0.1:$DEFAULT_PORT${COLOR_RESET}"
  print_summary_row "Health" "$(health_url)"
  if [[ -n "$launcher_pid" ]]; then
    print_summary_row "PID file" "$launcher_pid"
  else
    print_summary_row "PID file" "none"
  fi
  if [[ -n "$listener" ]]; then
    if pid_belongs_to_repo "$listener"; then
      print_summary_row "Listener" "$listener (this checkout)"
    else
      print_summary_row "Listener" "$listener (another process)"
    fi
  else
    print_summary_row "Listener" "none"
  fi
  if [[ -n "$repo_pids" ]]; then
    print_summary_row "Processes" "$(printf '%s' "$repo_pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  else
    print_summary_row "Processes" "none"
  fi
  if [[ -f "$LOG_FILE" ]]; then
    print_summary_row "Log" "$LOG_FILE"
  else
    print_summary_row "Log" "$LOG_FILE (not created)"
  fi

  [[ "$response" == *'"status":"ok"'* ]]
}

main() {
  local command="${1:-}"
  if [[ $# -ne 1 ]]; then
    usage
    exit 2
  fi
  case "$command" in
    start|stop|restart|status) ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac

  ensure_prerequisites
  if [[ "$command" == "status" ]]; then
    status_service
    exit $?
  fi
  acquire_lock

  case "$command" in
    start) start_service ;;
    stop) stop_service ;;
    restart)
      stop_service
      start_service
      ;;
  esac
}

main "$@"
