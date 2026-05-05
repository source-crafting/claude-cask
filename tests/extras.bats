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

@test "install rolls back manifest when docker build fails" {
  # docker build exits 1; everything else is OK.
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
if [[ "$1" == "build" ]]; then exit 1; fi
case "$1" in image) [[ "$2" == "inspect" ]] && exit 0 ;; esac
exit 0'

  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  mkdir -p "$HOME/.config/claude-cask"
  echo "ripgrep" > "$HOME/.config/claude-cask/apt.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" install --apt jq
  [ "$status" -ne 0 ]
  # Manifest is exactly what it was before — no `jq`.
  diff <(echo "ripgrep") "$HOME/.config/claude-cask/apt.list"
}

@test "remove --apt strips entries and rebuilds :user" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  mkdir -p "$HOME/.config/claude-cask"
  printf "ripgrep\njq\n" > "$HOME/.config/claude-cask/apt.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" remove --apt ripgrep
  [ "$status" -eq 0 ]
  diff <(echo "jq") "$HOME/.config/claude-cask/apt.list"
  grep -q "docker build -t claude-cask:user -" "$STUB_LOG"
  ! grep -q "^docker rmi" "$STUB_LOG"
}

@test "remove of unknown package is idempotent (exit 0, no rebuild)" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'
  mkdir -p "$HOME/.config/claude-cask"
  echo "ripgrep" > "$HOME/.config/claude-cask/apt.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" remove --apt nothere
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "not_present: nothere"
  ! grep -q "^docker build" "$STUB_LOG"
}

@test "removing the last entry across all manifests untags claude-cask:user" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  mkdir -p "$HOME/.config/claude-cask"
  echo "ripgrep" > "$HOME/.config/claude-cask/apt.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" remove --apt ripgrep
  [ "$status" -eq 0 ]
  ! grep -q "^docker build" "$STUB_LOG"
  grep -q "^docker rmi claude-cask:user$" "$STUB_LOG"
  [ ! -s "$HOME/.config/claude-cask/apt.list" ]
}

@test "TUI launch uses :user when any manifest is non-empty and :user exists with a fresh hash" {
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  mkdir -p "$HOME/.config/claude-cask"
  echo "ripgrep" > "$HOME/.config/claude-cask/apt.list"

  # Compute the SRC_HASH the launcher will derive from Dockerfile+entrypoint.sh
  # so the stub can return it for the image-hash label (avoiding base rebuild).
  ACTUAL_SRC_HASH="$(cat "$REPO_ROOT/Dockerfile" "$REPO_ROOT/entrypoint.sh" | shasum -a 256 | cut -d' ' -f1)"
  ACTUAL_UID="$(id -u)"
  ACTUAL_GID="$(id -g)"
  export ACTUAL_SRC_HASH ACTUAL_UID ACTUAL_GID

  # Compute the hash the launcher will compare against. Use stub docker in PATH
  # so user_hash() sees the same base image ID as the launcher will.
  # docker stub: pretend :latest and :user both exist; for :user, return
  # the same hash render_user_dockerfile would compute.
  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
if [[ "$1 $2" == "image inspect" ]]; then
  if [[ "$3" == "--format" ]]; then
    img="${*: -1}"  # last argument is the image name
    fmt="$4"
    case "$img" in
      claude-cask:latest)
        case "$fmt" in
          *claude-cask.uid*)        echo "$ACTUAL_UID" ;;
          *claude-cask.gid*)        echo "$ACTUAL_GID" ;;
          *claude-cask.image-hash*) echo "$ACTUAL_SRC_HASH" ;;
          *)                         echo "sha256:basebase" ;;
        esac
        ;;
      claude-cask:user)
        echo "$EXPECTED_USER_HASH"
        ;;
    esac
    exit 0
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_BIN/docker"

  # Precompute the expected user hash with the stub in PATH so user_hash()
  # sees sha256:basebase as the base image ID (same as the launcher will).
  CLAUDE_CASK_SOURCE_ONLY=1 source "$REPO_ROOT/claude-cask"
  EXPECTED_USER_HASH="$(PATH="$STUB_BIN:$PATH" user_hash)"
  export EXPECTED_USER_HASH

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* claude-cask:user" "$STUB_LOG"
  ! grep -q "docker run.* claude-cask:latest" "$STUB_LOG"
  # No rebuild — hash matched.
  ! grep -q "docker build -t claude-cask:user -" "$STUB_LOG"
}

@test "TUI launch uses :latest when all manifests are empty" {
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  ACTUAL_SRC_HASH="$(cat "$REPO_ROOT/Dockerfile" "$REPO_ROOT/entrypoint.sh" | shasum -a 256 | cut -d' ' -f1)"
  ACTUAL_UID="$(id -u)"
  ACTUAL_GID="$(id -g)"
  export ACTUAL_SRC_HASH ACTUAL_UID ACTUAL_GID

  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
{ printf 'docker'; printf ' %s' "$@"; printf '\n'; } >> "$STUB_LOG"
if [[ "$1 $2" == "image inspect" ]]; then
  if [[ "$3" == "--format" ]]; then
    fmt="$4"
    case "$fmt" in
      *claude-cask.uid*)        echo "$ACTUAL_UID" ;;
      *claude-cask.gid*)        echo "$ACTUAL_GID" ;;
      *claude-cask.image-hash*) echo "$ACTUAL_SRC_HASH" ;;
    esac
    exit 0
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_BIN/docker"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* claude-cask:latest" "$STUB_LOG"
  ! grep -q "docker run.* claude-cask:user" "$STUB_LOG"
}

@test "--bare forces :latest even when manifests are non-empty" {
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  ACTUAL_SRC_HASH="$(cat "$REPO_ROOT/Dockerfile" "$REPO_ROOT/entrypoint.sh" | shasum -a 256 | cut -d' ' -f1)"
  ACTUAL_UID="$(id -u)"
  ACTUAL_GID="$(id -g)"
  export ACTUAL_SRC_HASH ACTUAL_UID ACTUAL_GID

  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
{ printf 'docker'; printf ' %s' "$@"; printf '\n'; } >> "$STUB_LOG"
if [[ "$1 $2" == "image inspect" ]]; then
  if [[ "$3" == "--format" ]]; then
    fmt="$4"
    case "$fmt" in
      *claude-cask.uid*)        echo "$ACTUAL_UID" ;;
      *claude-cask.gid*)        echo "$ACTUAL_GID" ;;
      *claude-cask.image-hash*) echo "$ACTUAL_SRC_HASH" ;;
      *claude-cask.user-hash*)  echo "" ;;
    esac
    exit 0
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_BIN/docker"

  mkdir -p "$HOME/.config/claude-cask"
  echo "ripgrep" > "$HOME/.config/claude-cask/apt.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --bare
  [ "$status" -eq 0 ]
  grep -q "docker run.* claude-cask:latest" "$STUB_LOG"
  ! grep -q "docker run.* claude-cask:user" "$STUB_LOG"
  ! grep -q "docker build -t claude-cask:user -" "$STUB_LOG"
}

@test "--rebuild rebuilds :latest, then :user (when non-empty), and exits without TUI" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  mkdir -p "$HOME/.config/claude-cask"
  echo "ripgrep" > "$HOME/.config/claude-cask/apt.list"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --rebuild
  [ "$status" -eq 0 ]
  # :latest rebuilt
  grep -q "docker build .* -t claude-cask:latest " "$STUB_LOG"
  # :user rebuilt
  grep -q "docker build -t claude-cask:user -" "$STUB_LOG"
  # No TUI launch
  ! grep -q "docker run" "$STUB_LOG"
}

@test "--rebuild with empty manifests rebuilds only :latest" {
  stub_set docker "$(stub_docker_capture_stdin)"
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --rebuild
  [ "$status" -eq 0 ]
  grep -q "docker build .* -t claude-cask:latest " "$STUB_LOG"
  ! grep -q "docker build -t claude-cask:user -" "$STUB_LOG"
  ! grep -q "docker run" "$STUB_LOG"
}

@test "--update-claude-code passes CLAUDE_CODE_VERSION build-arg, rebuilds, exits" {
  stub_set docker "$(stub_docker_capture_stdin)"
  # `npm view ... version` is called on the host to resolve "latest".
  stub_set npm '#!/usr/bin/env bash
case "$1 $2" in
  "view @anthropic-ai/claude-code") echo "9.9.9"; exit 0 ;;
esac
exit 0'
  stub_set git '#!/usr/bin/env bash
case "$1 $2 $3" in
  "config --get user.name")  echo "Test User"; exit 0 ;;
  "config --get user.email") echo "test@example.com"; exit 0 ;;
esac
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --update-claude-code
  [ "$status" -eq 0 ]
  grep -q "docker build.*--build-arg CLAUDE_CODE_VERSION=9\.9\.9" "$STUB_LOG"
  grep -q "docker build.* -t claude-cask:latest " "$STUB_LOG"
  echo "$output" | grep -q "claude-code updated to 9.9.9"
  ! grep -q "docker run" "$STUB_LOG"
}
