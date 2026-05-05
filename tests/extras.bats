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

@test "render_user_dockerfile emits FROM and apt RUN when apt manifest non-empty" {
  load_launcher_funcs
  manifest_add apt ripgrep jq > /dev/null
  out="$(render_user_dockerfile)"
  echo "$out" | grep -q "^FROM claude-cask:latest$"
  echo "$out" | grep -q "apt-get install -y --no-install-recommends"
  echo "$out" | grep -q " ripgrep "
  echo "$out" | grep -q " jq"
  ! echo "$out" | grep -q "npm install"
  ! echo "$out" | grep -q "pipx install"
  ! echo "$out" | grep -q "cargo install"
}

@test "render_user_dockerfile pulls in pipx when pip manifest non-empty" {
  load_launcher_funcs
  manifest_add pip httpie > /dev/null
  out="$(render_user_dockerfile)"
  echo "$out" | grep -q "apt-get install -y --no-install-recommends.*pipx"
  echo "$out" | grep -q "pipx install"
  echo "$out" | grep -q "httpie"
}

@test "render_user_dockerfile pulls in cargo + build deps when cargo manifest non-empty" {
  load_launcher_funcs
  manifest_add cargo fd-find > /dev/null
  out="$(render_user_dockerfile)"
  echo "$out" | grep -q "apt-get install -y --no-install-recommends.* cargo"
  echo "$out" | grep -q "build-essential"
  echo "$out" | grep -q "pkg-config"
  echo "$out" | grep -q "libssl-dev"
  echo "$out" | grep -q "cargo install --root /usr/local"
  echo "$out" | grep -q "fd-find"
}

@test "render_user_dockerfile drops the apt RUN entirely when no apt-side work is needed" {
  load_launcher_funcs
  manifest_add npm prettier > /dev/null
  out="$(render_user_dockerfile)"
  ! echo "$out" | grep -q "apt-get install"
  echo "$out" | grep -q "npm install -g prettier"
}

@test "install --apt writes manifest and triggers docker build for :user" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" install --apt ripgrep jq

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "added: jq, ripgrep"
  [ -f "$HOME/.config/claude-cask/apt.list" ]
  grep -q "docker build -t claude-cask:user -" "$STUB_LOG"
  grep -q "^FROM claude-cask:latest$" "$STUB_BIN/docker-stdin.last"
  grep -q "ripgrep" "$STUB_BIN/docker-stdin.last"
  ! grep -q "^docker run" "$STUB_LOG"
}

@test "install with no --eco flag exits with usage error" {
  stub_set docker "$(stub_docker_capture_stdin)"
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" install ripgrep
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "ecosystem"
}

@test "install with no packages exits with usage error" {
  stub_set docker "$(stub_docker_capture_stdin)"
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" install --apt
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "package"
}
