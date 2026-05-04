#!/usr/bin/env bats

# Integration smoke test. Builds the image (if not present) and runs a few
# in-container assertions. Requires a working docker daemon.

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  docker build -t claude-cask:test "$REPO_ROOT" >/dev/null
}

@test "claude binary is installed in the image" {
  run docker run --rm --entrypoint claude claude-cask:test --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "entrypoint exec's claude when GIT_AUTHOR_* set and /workspace exists" {
  WORK="$(mktemp -d)"
  run docker run --rm \
    -v "$WORK:/workspace" \
    -e GIT_AUTHOR_NAME=Test -e GIT_AUTHOR_EMAIL=t@example.com \
    --entrypoint /usr/local/bin/entrypoint.sh \
    claude-cask:test --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "fresh container has no gpg secret keys when no signing key forwarded" {
  run docker run --rm --entrypoint gpg claude-cask:test --list-secret-keys
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "^sec"
}
