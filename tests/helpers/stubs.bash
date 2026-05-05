# Test helpers for stubbing external commands.
# Usage from a .bats test:
#   load helpers/stubs
#   stub_init
#   stub_set docker '#!/usr/bin/env bash
#   echo "docker $@" >> "$STUB_LOG"'
#   ...
#   PATH="$STUB_BIN:$PATH" run bash claude-cask --help

stub_init() {
  STUB_BIN="$(mktemp -d)"
  STUB_LOG="$STUB_BIN/calls.log"
  : > "$STUB_LOG"
  export STUB_BIN STUB_LOG
}

stub_teardown() {
  [[ -n "${STUB_BIN:-}" && -d "$STUB_BIN" ]] && rm -rf "$STUB_BIN"
}

# stub_set NAME SCRIPT_BODY
stub_set() {
  local name="$1"; shift
  local body="$1"
  local path="$STUB_BIN/$name"
  printf '%s\n' "$body" > "$path"
  chmod +x "$path"
}

stub_called() {
  grep -q "^$1" "$STUB_LOG"
}

# Returns a docker-stub script body that records argv to STUB_LOG and,
# when invoked as `docker build ... -`, copies stdin to
# $STUB_BIN/docker-stdin.last so tests can inspect the generated Dockerfile.
# Always exits 0; tests that need failures override with stub_set directly.
stub_docker_capture_stdin() {
  cat <<'STUB'
#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
if [[ "$1" == "build" ]]; then
  for a in "$@"; do
    if [[ "$a" == "-" ]]; then
      cat > "$(dirname "$0")/docker-stdin.last"
      break
    fi
  done
fi
case "$1" in
  image) [[ "$2" == "inspect" ]] && exit 0 ;;
esac
exit 0
STUB
}
