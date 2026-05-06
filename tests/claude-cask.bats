#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/stubs
  stub_init
  HOME="$(mktemp -d)"
  export HOME
  # Detach stdin from any inherited tty so the launcher's pre-flight
  # `Continue? [Y/n]` prompt (gated on `[[ -t 0 ]]`) doesn't hang the
  # suite when bats itself was invoked interactively. Subprocesses
  # spawned by `run` inherit this disconnected stdin.
  exec </dev/null
}

teardown() {
  stub_teardown
}

@test "bats harness works" {
  run echo "hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "entrypoint configures git author and exec's claude" {
  stub_set claude '#!/usr/bin/env bash
echo "claude called with: $@" >> "$STUB_LOG"
git config --global --get user.name  >> "$STUB_LOG"
git config --global --get user.email >> "$STUB_LOG"'

  HOME="$(mktemp -d)"
  export HOME GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com" CLAUDE_CASK_SKIP_WORKSPACE_CD=1
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/entrypoint.sh" --model opus --auto

  [ "$status" -eq 0 ]
  grep -q "^claude called with: --model opus --auto$" "$STUB_LOG"
  grep -q "^Test User$" "$STUB_LOG"
  grep -q "^test@example.com$" "$STUB_LOG"
}

@test "entrypoint imports single signing key when /tmp/signing-key.asc present" {
  stub_set claude '#!/usr/bin/env bash
echo "claude called" >> "$STUB_LOG"'

  stub_set gpg '#!/usr/bin/env bash
echo "gpg $@" >> "$STUB_LOG"
exit 0'

  stub_set git '#!/usr/bin/env bash
echo "git $@" >> "$STUB_LOG"
exit 0'

  HOME="$(mktemp -d)"
  TMPDIR_FOR_KEY="$(mktemp -d)"
  echo "FAKE PUBLIC KEY" > "$TMPDIR_FOR_KEY/signing-key.asc"

  export HOME GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com" CLAUDE_CASK_SKIP_WORKSPACE_CD=1
  export CLAUDE_CASK_SIGNING_KEY="ABCDEF1234567890"
  export CLAUDE_CASK_GPG_SIGN="true"
  export CLAUDE_CASK_KEY_PATH="$TMPDIR_FOR_KEY/signing-key.asc"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/entrypoint.sh" --model opus

  [ "$status" -eq 0 ]
  grep -qE "^gpg( --quiet)? --batch --import" "$STUB_LOG"
  grep -q "^git config --global user.signingkey ABCDEF1234567890$" "$STUB_LOG"
  grep -q "^git config --global commit.gpgsign true$" "$STUB_LOG"
  # The key file must NOT be removed by the entrypoint — under real use it
  # is a read-only bind-mount and `rm` fails with "Device or resource busy".
  [ -f "$TMPDIR_FOR_KEY/signing-key.asc" ]
}

# Helper: minimal stubs for docker, git so claude-cask can run.
launcher_default_stubs() {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
case "$1" in
  image) [[ "$2" == "inspect" ]] && exit 0 ;;
esac
exit 0'

  stub_set git '#!/usr/bin/env bash
echo "git $@" >> "$STUB_LOG"
# All four reads use natural git precedence (no --global, 3-word args).
case "$1 $2 $3" in
  "config --get user.name")       echo "Test User"; exit 0 ;;
  "config --get user.email")      echo "test@example.com"; exit 0 ;;
  "config --get user.signingkey") echo ""; exit 1 ;;
  "config --get commit.gpgsign")  echo "false"; exit 0 ;;
esac
exit 0'
}

@test "claude-cask --help prints usage and exits 0" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE:"* ]]
  [[ "$output" == *"--model"* ]]
  [[ "$output" == *"--auto"* ]]
  [[ "$output" == *"--keep-container"* ]]
}

@test "claude-cask defaults to --permission-mode default (overrides host settings)" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model opus --permission-mode default" "$STUB_LOG"
  ! grep -q "docker run.* --permission-mode auto" "$STUB_LOG"
}

@test "claude-cask --auto sets --permission-mode auto" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --auto
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model opus --permission-mode auto" "$STUB_LOG"
  ! grep -q "docker run.* --permission-mode default" "$STUB_LOG"
}

@test "claude-cask --model honors override" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --model sonnet
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model sonnet" "$STUB_LOG"
}

@test "claude-cask passes through args after --" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" -- --resume foo
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model opus --permission-mode default --resume foo" "$STUB_LOG"
}

@test "claude-cask prints pre-flight summary with workspace and mode" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace:"* ]]
  [[ "$output" == *"~/.claude:"* ]]
  [[ "$output" == *"mode:"* ]]
  [[ "$output" == *"safe"* ]]
}

@test "claude-cask summary reflects --auto flag" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"* ]]
  [[ "$output" == *"auto"* ]]
}

@test "claude-cask skips pre-flight prompt when stdin is not a tty" {
  launcher_default_stubs
  # setup() exec's </dev/null, so the spawned bash sees stdin as a regular
  # file (not a tty) and the [[ -t 0 ]] prompt gate is false → no prompt.
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Continue?"* ]]
}

@test "claude-cask exits 1 when docker is missing" {
  stub_set git '#!/usr/bin/env bash
echo "git $@" >> "$STUB_LOG"
exit 0'

  # Empty STUB_BIN means no docker; include system bin so bats can find bash itself.
  PATH="$STUB_BIN:/usr/bin:/bin" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker not found"* ]]
}

@test "claude-cask exits 1 when git user.name unset" {
  launcher_default_stubs
  stub_set git '#!/usr/bin/env bash
echo "git $@" >> "$STUB_LOG"
if [[ "$1 $2 $3" == "config --get user.name" ]]; then echo ""; exit 1; fi
if [[ "$1 $2 $3" == "config --get user.email" ]]; then echo "test@example.com"; exit 0; fi
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"user.name not set"* ]]
}

@test "claude-cask exits 1 when git user.email unset" {
  launcher_default_stubs
  stub_set git '#!/usr/bin/env bash
echo "git $@" >> "$STUB_LOG"
if [[ "$1 $2 $3" == "config --get user.name" ]]; then echo "Test User"; exit 0; fi
if [[ "$1 $2 $3" == "config --get user.email" ]]; then echo ""; exit 1; fi
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"user.email not set"* ]]
}

@test "claude-cask exports signing key and bind-mounts gpg-agent extra socket" {
  AGENT_SOCK_DIR="$(mktemp -d)"
  AGENT_SOCK="$AGENT_SOCK_DIR/S.gpg-agent.extra"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$AGENT_SOCK"

  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
case "$1" in
  image) [[ "$2" == "inspect" ]] && exit 0 ;;
esac
exit 0'

  stub_set git "#!/usr/bin/env bash
echo \"git \$@\" >> \"\$STUB_LOG\"
if [[ \"\$1 \$2 \$3\" == \"config --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.signingkey\" ]]; then echo 'ABCDEF1234567890'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get commit.gpgsign\" ]]; then echo 'true'; exit 0; fi
exit 0"

  stub_set gpg '#!/usr/bin/env bash
echo "gpg $@" >> "$STUB_LOG"
if [[ "$1" == "--export" && "$2" == "--armor" ]]; then
  echo "FAKE PUBLIC KEY $3"
  exit 0
fi
exit 0'

  stub_set gpgconf "#!/usr/bin/env bash
echo \"gpgconf \$@\" >> \"\$STUB_LOG\"
if [[ \"\$1 \$2\" == \"--list-dirs agent-extra-socket\" ]]; then echo '$AGENT_SOCK'; exit 0; fi
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "gpg --export --armor --export-options export-minimal ABCDEF1234567890!" "$STUB_LOG"
  grep -q "gpgconf --list-dirs agent-extra-socket" "$STUB_LOG"
  grep -q "docker run.*-v $AGENT_SOCK:/run/host-gpg-agent" "$STUB_LOG"
  grep -q "docker run.*-e CLAUDE_CASK_SIGNING_KEY=ABCDEF1234567890" "$STUB_LOG"
  grep -q "docker run.*-e CLAUDE_CASK_GPG_SIGN=true" "$STUB_LOG"
}

@test "claude-cask exits 1 when signing key configured but gpg-agent socket missing" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"; exit 0'

  stub_set git "#!/usr/bin/env bash
if [[ \"\$1 \$2 \$3\" == \"config --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.signingkey\" ]]; then echo 'ABCDEF1234567890'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get commit.gpgsign\" ]]; then echo 'true'; exit 0; fi
exit 0"

  stub_set gpg '#!/usr/bin/env bash
[[ "$1" == "--export" && "$2" == "--armor" ]] && { echo "FAKE KEY"; exit 0; }
exit 0'

  stub_set gpgconf '#!/usr/bin/env bash
echo "/nonexistent/path/S.gpg-agent.extra"
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gpg-agent extra socket not found"* ]]
}

@test "entrypoint fails when /workspace missing and CLAUDE_CASK_SKIP_WORKSPACE_CD unset" {
  stub_set claude '#!/usr/bin/env bash
echo "claude called" >> "$STUB_LOG"'

  HOME="$(mktemp -d)"
  export HOME GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@e
  unset CLAUDE_CASK_SKIP_WORKSPACE_CD || true

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/entrypoint.sh"
  [ "$status" -ne 0 ]
  ! grep -q "^claude called" "$STUB_LOG"
}

@test "claude-cask never reads the keychain on macOS hosts" {
  # The launcher relies on Claude Code's own /login flow to write
  # ~/.claude/.credentials.json on first launch (same path as Linux).
  # It must not call `security find-generic-password` on any platform.
  launcher_default_stubs
  mkdir -p "$HOME/.claude"

  stub_set uname '#!/usr/bin/env bash
echo "Darwin"'
  stub_set security '#!/usr/bin/env bash
echo "security $@" >> "$STUB_LOG"
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  ! grep -q "security find-generic-password" "$STUB_LOG"
  [ ! -f "$HOME/.claude/.credentials.json" ]
}

@test "claude-cask mounts ~/.claude.json when it exists on the host" {
  : > "$HOME/.claude.json"
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.*-v $HOME/.claude.json:/home/claude-cask/.claude.json" "$STUB_LOG"
}

@test "claude-cask does not mount ~/.claude.json when it is absent" {
  # HOME is a fresh tmpdir from setup(); .claude.json does not exist.
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  ! grep -q ".claude.json:/home/claude-cask/.claude.json" "$STUB_LOG"
}

@test "claude-cask forwards terminal env vars when present on host" {
  launcher_default_stubs

  TERM_PROGRAM=iTerm.app TERM_PROGRAM_VERSION=3.6.10 COLORTERM=truecolor \
    PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.*-e TERM_PROGRAM=iTerm.app" "$STUB_LOG"
  grep -q "docker run.*-e TERM_PROGRAM_VERSION=3.6.10" "$STUB_LOG"
  grep -q "docker run.*-e COLORTERM=truecolor" "$STUB_LOG"
}

@test "claude-cask omits terminal env vars that are unset on host" {
  launcher_default_stubs

  unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  ! grep -q "docker run.*-e TERM_PROGRAM=" "$STUB_LOG"
  ! grep -q "docker run.*-e COLORTERM=" "$STUB_LOG"
}

@test "claude-cask defaults to --rm (ephemeral container)" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  # Launcher composes `docker run -it --rm …` so allow flags between.
  grep -q "docker run.* --rm" "$STUB_LOG"
  ! grep -q "docker run.* --cidfile" "$STUB_LOG"
}

@test "claude-cask --keep-container drops --rm and adds --cidfile" {
  launcher_default_stubs
  # docker stub: write a fake container id to whatever path is passed
  # to --cidfile so the post-run hint logic has something to print.
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in image) [[ \"\$2\" == \"inspect\" ]] && exit 0 ;; esac
# Find the --cidfile arg and write a fake id there.
prev=\"\"
for a in \"\$@\"; do
  if [[ \"\$prev\" == \"--cidfile\" ]]; then
    echo fake-cid-1234 > \"\$a\"
    break
  fi
  prev=\"\$a\"
done
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --keep-container
  [ "$status" -eq 0 ]
  ! grep -q "docker run.* --rm" "$STUB_LOG"
  grep -qE "docker run.* --cidfile /[^ ]+" "$STUB_LOG"
  [[ "$output" == *"container kept for post-mortem"* ]]
  [[ "$output" == *"fake-cid-1234"* ]]
  [[ "$output" == *"docker logs fake-cid-1234"* ]]
  [[ "$output" == *"docker rm fake-cid-1234"* ]]
}

@test "claude-cask exits 2 on unknown launcher flag before --" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --not-a-real-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag '--not-a-real-flag'"* ]]
}

@test "claude-cask still allows unknown flags after --" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" -- --not-a-real-flag value
  [ "$status" -eq 0 ]
  grep -q "docker run.*--not-a-real-flag value" "$STUB_LOG"
}

@test "claude-cask does not RO-mount settings.json or any of plugins/" {
  # ~/.claude is mounted RW so Claude can manage its own state inside the
  # container (install plugins, refresh marketplaces, update enabledPlugins
  # in settings.json). No RO overlays are layered on top of those paths.
  launcher_default_stubs
  mkdir -p "$HOME/.claude/plugins/cache"
  echo "{}" > "$HOME/.claude/settings.json"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  ! grep -q "settings.json:.*:ro" "$STUB_LOG"
  ! grep -q "plugins.*:ro" "$STUB_LOG"
}

@test "claude-cask mirrors PWD at the same in-container path (no /workspace collision)" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  # Mount source and target are both $PWD.
  grep -q "docker run.*-v $PWD:$PWD" "$STUB_LOG"
  # Working directory inside the container is also $PWD.
  grep -q "docker run.*-w $PWD" "$STUB_LOG"
  # And the entrypoint gets the path via env var.
  grep -q "docker run.*-e CLAUDE_CASK_WORKDIR=$PWD" "$STUB_LOG"
  # The old /workspace wiring is gone.
  ! grep -q "docker run.*:/workspace" "$STUB_LOG"
}

@test "claude-cask aborts cleanly on a circular launcher symlink" {
  launcher_default_stubs

  # Build A → B → A. Invoking through either should error within the hop
  # limit rather than infinite-looping.
  LINK_DIR="$(mktemp -d)"
  ln -s "$LINK_DIR/B" "$LINK_DIR/A"
  ln -s "$LINK_DIR/A" "$LINK_DIR/B"

  PATH="$STUB_BIN:$PATH" run bash "$LINK_DIR/A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too many symlink hops"* ]]

  rm -rf "$LINK_DIR"
}

@test "claude-cask resolves symlinked launcher path for docker build context" {
  launcher_default_stubs

  # Make image-inspect "fail" so the launcher reaches the build path.
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image) [[ \"\$2\" == \"inspect\" ]] && exit 1 ;;
esac
exit 0"

  # Place a symlink to the real launcher into a different directory.
  LINK_DIR="$(mktemp -d)"
  ln -s "$REPO_ROOT/claude-cask" "$LINK_DIR/claude-cask"

  # Invoke through the symlink. Without symlink resolution, SCRIPT_DIR would
  # be $LINK_DIR and the docker build context would be wrong.
  PATH="$STUB_BIN:$PATH" run bash "$LINK_DIR/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker build .*-t claude-cask:latest $REPO_ROOT" "$STUB_LOG"
  ! grep -q "docker build .*-t claude-cask:latest $LINK_DIR" "$STUB_LOG"

  rm -rf "$LINK_DIR"
}

@test "claude-cask pre-flight summary shows 'filevault: on' when fdesetup reports on (Darwin)" {
  launcher_default_stubs
  stub_set uname '#!/usr/bin/env bash
echo "Darwin"'
  stub_set fdesetup '#!/usr/bin/env bash
echo "FileVault is On."'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" == *"filevault:    on"* ]]
  [[ "$output" != *"OFF"* ]]
}

@test "claude-cask pre-flight summary warns when FileVault is off (Darwin)" {
  launcher_default_stubs
  stub_set uname '#!/usr/bin/env bash
echo "Darwin"'
  stub_set fdesetup '#!/usr/bin/env bash
echo "FileVault is Off."'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" == *"filevault:    OFF"* ]]
  [[ "$output" == *"plaintext at rest"* ]]
}

@test "claude-cask omits filevault line on non-Darwin hosts" {
  launcher_default_stubs
  stub_set uname '#!/usr/bin/env bash
echo "Linux"'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" != *"filevault:"* ]]
}

@test "claude-cask passes host UID/GID and source hash as build args when building" {
  launcher_default_stubs
  # Force a build by making image-inspect "fail" so the launcher reaches
  # the build path.
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image) [[ \"\$2\" == \"inspect\" ]] && exit 1 ;;
esac
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -qE "docker build .*--build-arg USER_UID=$(id -u)" "$STUB_LOG"
  grep -qE "docker build .*--build-arg USER_GID=$(id -g)" "$STUB_LOG"
  grep -qE "docker build .*--build-arg IMAGE_HASH=[0-9a-f]{64}" "$STUB_LOG"
}

@test "claude-cask prunes dangling claude-cask images after a build" {
  launcher_default_stubs
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image) [[ \"\$2\" == \"inspect\" ]] && exit 1 ;;
esac
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  # The prune happens after the build and is scoped via our label.
  grep -q "docker image prune -f --filter label=claude-cask.uid" "$STUB_LOG"
}

@test "claude-cask does not prune when no build happened" {
  launcher_default_stubs
  HU="$(id -u)"
  HG="$(id -g)"
  HH="$(cat "$REPO_ROOT/Dockerfile" "$REPO_ROOT/entrypoint.sh" | shasum -a 256 | cut -d' ' -f1)"
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image)
    if [[ \"\$2\" == \"inspect\" ]]; then
      if [[ \"\$3\" == \"--format\" ]]; then
        case \"\$4\" in
          *claude-cask.uid*) echo $HU ;;
          *claude-cask.gid*) echo $HG ;;
          *claude-cask.image-hash*) echo $HH ;;
        esac
      fi
      exit 0
    fi
    ;;
esac
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  ! grep -q "docker image prune" "$STUB_LOG"
}

@test "claude-cask auto-rebuilds when image source-hash differs from current Dockerfile/entrypoint" {
  launcher_default_stubs
  HU="$(id -u)"
  HG="$(id -g)"
  # docker stub: image exists, UID/GID labels match host, but image-hash
  # label is a stale value that doesn't match the current source.
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image)
    if [[ \"\$2\" == \"inspect\" ]]; then
      if [[ \"\$3\" == \"--format\" ]]; then
        case \"\$4\" in
          *claude-cask.uid*) echo $HU ;;
          *claude-cask.gid*) echo $HG ;;
          *claude-cask.image-hash*) echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef ;;
        esac
      fi
      exit 0
    fi
    ;;
esac
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dockerfile or entrypoint.sh changed since last build"* ]]
  grep -q "docker build " "$STUB_LOG"
}

@test "claude-cask auto-rebuilds when image label UID/GID differ from host" {
  launcher_default_stubs
  # docker stub: image-inspect returns the image, with a "wrong" label that
  # doesn't match the host UID/GID. The launcher should detect this and
  # trigger a rebuild.
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image)
    if [[ \"\$2\" == \"inspect\" ]]; then
      # Mimic both inspect calls: the existence check and the label fetch.
      if [[ \"\$3\" == \"--format\" ]]; then
        case \"\$4\" in
          *claude-cask.uid*) echo 999 ;;
          *claude-cask.gid*) echo 999 ;;
        esac
      fi
      exit 0
    fi
    ;;
esac
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  [[ "$output" == *"image was built for UID/GID 999:999"* ]]
  grep -q "docker build " "$STUB_LOG"
}

@test "claude-cask skips rebuild when all labels match (UID/GID + image-hash)" {
  launcher_default_stubs
  HU="$(id -u)"
  HG="$(id -g)"
  HH="$(cat "$REPO_ROOT/Dockerfile" "$REPO_ROOT/entrypoint.sh" | shasum -a 256 | cut -d' ' -f1)"
  stub_set docker "#!/usr/bin/env bash
echo \"docker \$@\" >> \"\$STUB_LOG\"
case \"\$1\" in
  image)
    if [[ \"\$2\" == \"inspect\" ]]; then
      if [[ \"\$3\" == \"--format\" ]]; then
        case \"\$4\" in
          *claude-cask.uid*) echo $HU ;;
          *claude-cask.gid*) echo $HG ;;
          *claude-cask.image-hash*) echo $HH ;;
        esac
      fi
      exit 0
    fi
    ;;
esac
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  ! grep -q "docker build" "$STUB_LOG"
}

@test "claude-cask --rebuild forces a rebuild even when image exists" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --rebuild
  [ "$status" -eq 0 ]
  grep -q "docker build .*-t claude-cask:latest" "$STUB_LOG"
}

@test "claude-cask exits 1 when gpg export is empty" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"; exit 0'

  stub_set git "#!/usr/bin/env bash
if [[ \"\$1 \$2 \$3\" == \"config --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.signingkey\" ]]; then echo 'NOSUCHKEY'; exit 0; fi
exit 0"

  stub_set gpg '#!/usr/bin/env bash
exit 0'

  stub_set gpgconf '#!/usr/bin/env bash
echo "/tmp/anywhere"; exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to export signing key"* ]]
}

@test "claude-cask user.name local overrides global" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
case "$1" in
  image) [[ "$2" == "inspect" ]] && exit 0 ;;
esac
exit 0'

  stub_set git "#!/usr/bin/env bash
echo \"git \$@\" >> \"\$STUB_LOG\"
# 3-arg form (no --global): git's natural precedence — local wins.
if [[ \"\$1 \$2 \$3\" == \"config --get user.name\" ]]; then echo 'Local User'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.email\" ]]; then echo 'local@example.com'; exit 0; fi
# Signing keys still queried with --global.
if [[ \"\$1 \$2 \$3\" == \"config --get user.signingkey\" ]]; then echo ''; exit 1; fi
if [[ \"\$1 \$2 \$3\" == \"config --get commit.gpgsign\" ]]; then echo 'false'; exit 0; fi
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* -e GIT_AUTHOR_NAME=Local User" "$STUB_LOG"
  grep -q "docker run.* -e GIT_AUTHOR_EMAIL=local@example.com" "$STUB_LOG"
}

@test "claude-cask user.email local overrides global" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
case "$1" in
  image) [[ "$2" == "inspect" ]] && exit 0 ;;
esac
exit 0'

  stub_set git "#!/usr/bin/env bash
echo \"git \$@\" >> \"\$STUB_LOG\"
if [[ \"\$1 \$2 \$3\" == \"config --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.email\" ]]; then echo 'override@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.signingkey\" ]]; then echo ''; exit 1; fi
if [[ \"\$1 \$2 \$3\" == \"config --get commit.gpgsign\" ]]; then echo 'false'; exit 0; fi
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* -e GIT_AUTHOR_EMAIL=override@example.com" "$STUB_LOG"
}

@test "claude-cask user.signingkey local overrides global" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"
case "$1" in
  image) [[ "$2" == "inspect" ]] && exit 0 ;;
esac
exit 0'

  AGENT_SOCK="$(mktemp -u)"
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$AGENT_SOCK"
  stub_set gpgconf "#!/usr/bin/env bash
[[ \"\$1\" == '--list-dirs' && \"\$2\" == 'agent-extra-socket' ]] && echo '$AGENT_SOCK'
exit 0"
  stub_set gpg '#!/usr/bin/env bash
case "$1 $2" in
  "--export --armor") echo "FAKE PUBLIC KEY" ;;
esac
exit 0'

  stub_set git "#!/usr/bin/env bash
echo \"git \$@\" >> \"\$STUB_LOG\"
# git's natural precedence: a local signingkey wins over global. The launcher
# only invokes the 3-arg form, so returning LOCALKEY here is what reaches
# the container env.
if [[ \"\$1 \$2 \$3\" == \"config --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get user.signingkey\" ]]; then echo 'LOCALKEY'; exit 0; fi
if [[ \"\$1 \$2 \$3\" == \"config --get commit.gpgsign\" ]]; then echo 'false'; exit 0; fi
exit 0"

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* -e CLAUDE_CASK_SIGNING_KEY=LOCALKEY" "$STUB_LOG"

  rm -f "$AGENT_SOCK"
}

@test "claude-cask forwards HOST_HOME so plugin paths resolve in container" {
  launcher_default_stubs
  HOME="/Users/testuser"
  export HOME
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* -e HOST_HOME=/Users/testuser" "$STUB_LOG"
}

@test "entrypoint creates HOST_HOME symlink to /home/claude-cask" {
  # Run the entrypoint's root-side setup in a sandbox: redirect mkdir/ln
  # via stubs and confirm the right ln -sfn invocation is issued. The
  # real entrypoint exec's gosu after the symlink, so we use a gosu stub
  # that records and exits.
  stub_set gosu '#!/usr/bin/env bash
echo "gosu $@" >> "$STUB_LOG"
exit 0'

  # The entrypoint's privileged section only runs when EUID==0, but the
  # tests run as a regular user. Point id at a stub that lies.
  stub_set id '#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then echo 0; exit 0; fi
exit 0'

  # Capture mkdir + ln so we don't actually mutate the test host's FS.
  stub_set mkdir '#!/usr/bin/env bash
echo "mkdir $@" >> "$STUB_LOG"
exit 0'
  stub_set ln '#!/usr/bin/env bash
echo "ln $@" >> "$STUB_LOG"
exit 0'

  HOST_HOME="/Users/testuser"
  export HOST_HOME GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com"
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/entrypoint.sh"

  # We don't assert exit status — the entrypoint exec's gosu, which our
  # stub turns into a no-op exit 0; we care that the symlink was issued.
  grep -q "^mkdir -p /Users$" "$STUB_LOG"
  grep -q "^ln -sfn /home/claude-cask /Users/testuser$" "$STUB_LOG"
}

@test "entrypoint skips HOST_HOME symlink when value matches container home" {
  stub_set gosu '#!/usr/bin/env bash
echo "gosu $@" >> "$STUB_LOG"
exit 0'
  stub_set id '#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then echo 0; exit 0; fi
exit 0'
  stub_set mkdir '#!/usr/bin/env bash
echo "mkdir $@" >> "$STUB_LOG"
exit 0'
  stub_set ln '#!/usr/bin/env bash
echo "ln $@" >> "$STUB_LOG"
exit 0'

  HOST_HOME="/home/claude-cask"
  export HOST_HOME GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com"
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/entrypoint.sh"

  ! grep -q "^ln -sfn /home/claude-cask /home/claude-cask" "$STUB_LOG"
}
