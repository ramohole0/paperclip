#!/usr/bin/env bash

# If invoked through /bin/sh (which lacks process substitution, [[ ]], etc.),
# re-exec the script under bash so the Bash-only syntax works as intended.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# Install dependencies and build the Paperclip project from a clean checkout.
#
# Usage:
#   ./build.sh              # install dependencies, then build (same as "all")
#   ./build.sh all          # install dependencies, then build
#   ./build.sh install      # install dependencies only
#   ./build.sh build        # build only (installs deps automatically if missing)
#   ./build.sh typecheck    # run the type checker (installs deps if missing)
#   ./build.sh clean        # remove build artifacts (dist directories only)
#   ./build.sh help         # show this help
#
# Environment:
#   SKIP_INSTALL=1          Skip the automatic dependency install before build/typecheck
#   BUILD_LOG=<path>        Where to tee build output (default: .paperclip/build.log)
#   NO_COLOR=1              Disable colored output

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
STATE_DIR="$REPO_ROOT/.paperclip"
LOG_FILE="${BUILD_LOG:-$STATE_DIR/build.log}"
LOCK_DIR="$STATE_DIR/build.lock"
EXPECTED_PNPM_VERSION="9.15.4"
PNPM_BIN=""
SKIP_INSTALL="${SKIP_INSTALL:-0}"

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

BUILD_LABEL="${COLOR_BOLD}${COLOR_CYAN}Paperclip${COLOR_RESET}${COLOR_DIM} build${COLOR_RESET}"

print_status() {
  local color="$1"
  local label="$2"
  shift 2
  printf '%b %b%-7s%b %s\n' "$BUILD_LABEL" "$color" "$label" "$COLOR_RESET" "$*"
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

print_summary_row() {
  local label="$1"
  local value="$2"
  printf '  %b%-9s%b %s\n' "$COLOR_DIM" "$label" "$COLOR_RESET" "$value"
}

usage() {
  printf '%b\n' "${COLOR_BOLD}Paperclip build${COLOR_RESET}"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Usage:${COLOR_RESET} ./build.sh [command]"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Commands:${COLOR_RESET}"
  printf '  %b%-10s%b %s\n' "$COLOR_GREEN" "all" "$COLOR_RESET" "Install dependencies, then build (default when no command given)"
  printf '  %b%-10s%b %s\n' "$COLOR_GREEN" "install" "$COLOR_RESET" "Install dependencies only"
  printf '  %b%-10s%b %s\n' "$COLOR_CYAN" "build" "$COLOR_RESET" "Build all packages (installs deps automatically if missing)"
  printf '  %b%-10s%b %s\n' "$COLOR_BLUE" "typecheck" "$COLOR_RESET" "Type-check all packages (installs deps if missing)"
  printf '  %b%-10s%b %s\n' "$COLOR_YELLOW" "clean" "$COLOR_RESET" "Remove build artifacts (gitignored dist directories only)"
  printf '  %b%-10s%b %s\n' "$COLOR_DIM" "help" "$COLOR_RESET" "Show this help"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Environment:${COLOR_RESET}"
  printf '  %-42s %s\n' "SKIP_INSTALL=1" "Do not auto-install before build/typecheck"
  printf '  %-42s %s\n' "BUILD_LOG=<path>" "Tee build output to this file"
  printf '  %-42s %s\n' "NO_COLOR=1" "Disable colored output"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
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
  node_major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true)"
  [[ "$node_major" =~ ^[0-9]+$ ]] || die "Unable to determine the Node.js version"
  (( node_major >= 20 )) || die "Node.js 20 or newer is required (found $(node --version))"
  resolve_pnpm
  [[ -f "$REPO_ROOT/package.json" ]] || die "Repository package.json not found at $REPO_ROOT"
  mkdir -p "$(dirname "$LOG_FILE")"
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
  if [[ -n "$owner" ]] && [[ "$owner" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner" 2>/dev/null; then
    die "Another build operation is active (pid $owner)"
  fi

  warn "Removing stale build lock"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || die "Unable to acquire build lock"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

deps_are_installed() {
  [[ -x "$REPO_ROOT/server/node_modules/.bin/tsx" ]]
}

run_pnpm() {
  local subcommand="$1"
  step "Running: pnpm $subcommand"
  "$PNPM_BIN" $subcommand 2>&1 | tee -a "$LOG_FILE"
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    die "pnpm $subcommand failed (see $LOG_FILE)"
  fi
}

run_install() {
  step "Installing dependencies"
  run_pnpm "install"
  success "Dependencies installed"
}

run_build() {
  step "Building all packages"
  run_pnpm "build"
  success "Build complete"
}

run_typecheck() {
  step "Type-checking all packages"
  run_pnpm "typecheck"
  success "Type-check complete"
}

ensure_deps_or_install() {
  if deps_are_installed; then
    return 0
  fi
  if (( SKIP_INSTALL )); then
    die "Dependencies are missing and SKIP_INSTALL=1; run: $0 install"
  fi
  warn "Dependencies are missing; installing now"
  run_install
}

clean_artifacts() {
  step "Removing build artifacts (dist directories)"
  local count_file removed
  count_file="$(mktemp -t paperclip-build-clean.XXXXXX)"
  find "$REPO_ROOT" -type d -name dist -not -path '*/node_modules/*' -print0 2>/dev/null \
    | while IFS= read -r -d '' dir; do
        # Only delete directories git already treats as ignored (generated output),
        # never tracked source or node_modules.
        if git -C "$REPO_ROOT" check-ignore -q "$dir" 2>/dev/null; then
          rm -rf "$dir"
          success "removed $dir"
          printf '1\n' >>"$count_file"
        else
          warn "skipping $dir (not gitignored; refusing to delete)"
        fi
      done
  removed="$(wc -l <"$count_file" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  rm -f "$count_file"
  if (( removed == 0 )); then
    info "no build artifacts to remove"
  elif (( removed == 1 )); then
    success "removed 1 build artifact directory"
  else
    success "removed $removed build artifact directories"
  fi
}

main() {
  local command="${1:-all}"

  case "$command" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  case "$command" in
    all|install|build|typecheck|clean) ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac

  ensure_prerequisites
  acquire_lock

  print_summary_row "Repo" "$REPO_ROOT"
  print_summary_row "pnpm" "$PNPM_BIN ($EXPECTED_PNPM_VERSION)"
  print_summary_row "Log" "$LOG_FILE"

  case "$command" in
    install)
      run_install
      ;;
    build)
      ensure_deps_or_install
      run_build
      ;;
    typecheck)
      ensure_deps_or_install
      run_typecheck
      ;;
    all)
      run_install
      run_build
      ;;
    clean)
      clean_artifacts
      ;;
  esac

  success "$(green_text "Done"); '$command' finished"
}

main "$@"
