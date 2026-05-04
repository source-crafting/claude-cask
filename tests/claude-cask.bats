#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/stubs
  stub_init
  HOME="$(mktemp -d)"
  export HOME
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
  grep -q "^gpg --batch --import" "$STUB_LOG"
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
case "$1 $2 $3 $4" in
  "config --global --get user.name")       echo "Test User"; exit 0 ;;
  "config --global --get user.email")      echo "test@example.com"; exit 0 ;;
  "config --global --get user.signingkey") echo ""; exit 1 ;;
  "config --global --get commit.gpgsign")  echo "false"; exit 0 ;;
esac
exit 0'
}

@test "claude-cask --help prints usage and exits 0" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE:"* ]]
  [[ "$output" == *"--model"* ]]
  [[ "$output" == *"--safe"* ]]
}

@test "claude-cask defaults to --model opus and --permission-mode auto" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model opus --permission-mode auto" "$STUB_LOG"
}

@test "claude-cask --safe omits --permission-mode auto" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --safe
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model opus" "$STUB_LOG"
  ! grep -q "docker run.* --permission-mode" "$STUB_LOG"
}

@test "claude-cask --model honors override" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --model sonnet
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model sonnet --permission-mode auto" "$STUB_LOG"
}

@test "claude-cask passes through args after --" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" -- --resume foo
  [ "$status" -eq 0 ]
  grep -q "docker run.* --model opus --permission-mode auto --resume foo" "$STUB_LOG"
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
if [[ "$1 $2 $3 $4" == "config --global --get user.name" ]]; then echo ""; exit 1; fi
if [[ "$1 $2 $3 $4" == "config --global --get user.email" ]]; then echo "test@example.com"; exit 0; fi
exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"user.name not set"* ]]
}

@test "claude-cask exits 1 when git user.email unset" {
  launcher_default_stubs
  stub_set git '#!/usr/bin/env bash
echo "git $@" >> "$STUB_LOG"
if [[ "$1 $2 $3 $4" == "config --global --get user.name" ]]; then echo "Test User"; exit 0; fi
if [[ "$1 $2 $3 $4" == "config --global --get user.email" ]]; then echo ""; exit 1; fi
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
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.signingkey\" ]]; then echo 'ABCDEF1234567890'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get commit.gpgsign\" ]]; then echo 'true'; exit 0; fi
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
  grep -q "gpg --export --armor ABCDEF1234567890" "$STUB_LOG"
  grep -q "gpgconf --list-dirs agent-extra-socket" "$STUB_LOG"
  grep -q "docker run.*-v $AGENT_SOCK:/root/.gnupg/S.gpg-agent" "$STUB_LOG"
  grep -q "docker run.*-e CLAUDE_CASK_SIGNING_KEY=ABCDEF1234567890" "$STUB_LOG"
  grep -q "docker run.*-e CLAUDE_CASK_GPG_SIGN=true" "$STUB_LOG"
}

@test "claude-cask exits 1 when signing key configured but gpg-agent socket missing" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"; exit 0'

  stub_set git "#!/usr/bin/env bash
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.signingkey\" ]]; then echo 'ABCDEF1234567890'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get commit.gpgsign\" ]]; then echo 'true'; exit 0; fi
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

@test "claude-cask --rebuild forces a rebuild even when image exists" {
  launcher_default_stubs
  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask" --rebuild
  [ "$status" -eq 0 ]
  grep -q "docker build -t claude-cask:latest" "$STUB_LOG"
}

@test "claude-cask exits 1 when gpg export is empty" {
  stub_set docker '#!/usr/bin/env bash
echo "docker $@" >> "$STUB_LOG"; exit 0'

  stub_set git "#!/usr/bin/env bash
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.name\" ]]; then echo 'Test User'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.email\" ]]; then echo 'test@example.com'; exit 0; fi
if [[ \"\$1 \$2 \$3 \$4\" == \"config --global --get user.signingkey\" ]]; then echo 'NOSUCHKEY'; exit 0; fi
exit 0"

  stub_set gpg '#!/usr/bin/env bash
exit 0'

  stub_set gpgconf '#!/usr/bin/env bash
echo "/tmp/anywhere"; exit 0'

  PATH="$STUB_BIN:$PATH" run bash "$REPO_ROOT/claude-cask"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to export signing key"* ]]
}
