#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/stubs
  stub_init
  HOME="$(mktemp -d)"
  export HOME
  exec </dev/null
}

teardown() {
  stub_teardown
}

@test "docker stub captures stdin when build - is invoked" {
  stub_set docker "$(stub_docker_capture_stdin)"
  echo "FROM scratch" | "$STUB_BIN/docker" build -t foo -
  [ -f "$STUB_BIN/docker-stdin.last" ]
  grep -q "^FROM scratch$" "$STUB_BIN/docker-stdin.last"
}

@test "list with no manifests prints '(no extras configured)' and exits 0" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no extras configured"
  ! grep -q "^docker run" "$STUB_LOG"
  ! grep -q "^docker build" "$STUB_LOG"
}

@test "list prints contents grouped by ecosystem when manifests have entries" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  mkdir -p "$HOME/.config/claude-cask"
  printf "ripgrep\njq\n" > "$HOME/.config/claude-cask/apt.list"
  printf "prettier\n"     > "$HOME/.config/claude-cask/npm.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^\[apt\]$"
  echo "$output" | grep -q "^ripgrep$"
  echo "$output" | grep -q "^jq$"
  echo "$output" | grep -q "^\[npm\]$"
  echo "$output" | grep -q "^prettier$"
  ! echo "$output" | grep -q "no extras configured"
}

# Helper: source the launcher's functions without executing the script.
# We mark a guard env so claude-cask returns early before doing real work.
load_launcher_funcs() {
  # shellcheck source=/dev/null
  CLAUDE_CASK_SOURCE_ONLY=1 source "$REPO_ROOT/claude-cask"
}

@test "manifest_add deduplicates and sorts" {
  load_launcher_funcs
  manifest_add apt ripgrep jq ripgrep > /tmp/out
  [ "$(manifest_read apt)" = "$(printf 'jq\nripgrep')" ]
  grep -q "added: jq, ripgrep" /tmp/out
  grep -q "already: ripgrep" /tmp/out
}

@test "manifest_remove is idempotent" {
  load_launcher_funcs
  manifest_add apt ripgrep jq > /dev/null
  manifest_remove apt ripgrep nonexistent > /tmp/out
  [ "$(manifest_read apt)" = "jq" ]
  grep -q "removed: ripgrep" /tmp/out
  grep -q "not_present: nonexistent" /tmp/out
}
