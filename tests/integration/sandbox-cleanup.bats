#!/usr/bin/env bats
# Sandbox cleanup tests

setup_test_env() {
  TEST_TMPDIR=$(mktemp -d -t dev-sandbox-test-XXXXXX)
  export TEST_TMPDIR

  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "$HOME"

  export XDG_CACHE_HOME="${TEST_TMPDIR}/cache"
  export XDG_CONFIG_HOME="${TEST_TMPDIR}/config"
  export XDG_DATA_HOME="${TEST_TMPDIR}/data"
  mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

  export NIX_LOG_COLOR=0

  # Set project root path for use in tests
  if [ -d "./dev-sandbox" ]; then
    # Running in nix build sandbox (dev-sandbox copied to ./dev-sandbox)
    export DEV_SANDBOX_ROOT="${PWD}/dev-sandbox"
  else
    # Running locally (use PWD from bats invocation)
    export DEV_SANDBOX_ROOT="${PWD}/../.."
  fi
}

teardown_test_env() {
  pkill -f "postgres.*${TEST_TMPDIR}" || true
  sleep 1
  rm -rf "${TEST_TMPDIR}"
}

setup() {
  setup_test_env

  TEST_PROJECT_DIR="${TEST_TMPDIR}/test-project"
  mkdir -p "${TEST_PROJECT_DIR}"

  cat > "${TEST_PROJECT_DIR}/flake.nix" <<EOF
{
  description = "Test project for dev-sandbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    dev-sandbox.url = "path:$DEV_SANDBOX_ROOT";
  };

  outputs = { self, nixpkgs, dev-sandbox }: {
    devShells.x86_64-linux.default = (dev-sandbox.lib { system = "x86_64-linux"; }).mkSandbox {
      projectRoot = ./.;
      services.postgres = true;
    };
  };
}
EOF
}

teardown() {
  teardown_test_env
}

@test "sandbox-list shows no sandboxes initially" {
  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-list
  ')

  [[ "$OUTPUT" == *"No sandboxes found"* ]]
}

@test "sandbox-list shows created instances" {
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
  '

  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-list
  ')

  [[ "$OUTPUT" != *"No sandboxes found"* ]]
  [[ "$OUTPUT" == *"- "* ]]
}

@test "sandbox-cleanup removes all sandboxes" {
  # Create two instances
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    db_start
  '

  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
  '

  # Verify sandboxes exist
  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-list
  ')
  [[ "$OUTPUT" != *"No sandboxes found"* ]]

  # Run cleanup
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-cleanup
  '

  # Verify sandboxes are removed
  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-list
  ')
  [[ "$OUTPUT" == *"No sandboxes found"* ]]
}

@test "sandbox-cleanup stops running PostgreSQL instances" {
  # Start an instance
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    db_start

    # Get PostgreSQL PID
    pg_ctl -D "$PGDATA" status | head -n1
  '

  # Run cleanup
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-cleanup
  '

  # Verify no PostgreSQL processes are running in test directory
  pgrep -f "postgres.*${TEST_TMPDIR}" || true
  RESULT=$?
  [ "$RESULT" -ne 0 ]
}

@test "sandbox-cleanup removes data directories" {
  # Create an instance
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    db_start
  '

  # Verify data directory exists
  RUN=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    if [ -d "${TEST_PROJECT_DIR}/.sandboxes" ]; then
      find "${TEST_PROJECT_DIR}/.sandboxes" -name "PG_VERSION" | wc -l
    else
      echo "0"
    fi
  ')
  [ "$RUN" -gt 0 ]

  # Run cleanup
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-cleanup
  '

  # Verify no data directories remain
  RUN=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    if [ -d "${TEST_PROJECT_DIR}/.sandboxes" ]; then
      find "${TEST_PROJECT_DIR}/.sandboxes" -name "PG_VERSION" 2>/dev/null | wc -l
    else
      echo "0"
    fi
  ')
  [ "$RUN" -eq 0 ]
}

@test "sandbox-cleanup reports number of removed sandboxes" {
  # Create three instances
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c 'source /etc/set-environment 2>/dev/null || true; echo "$SANDBOX_INSTANCE_ID"'
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c 'source /etc/set-environment 2>/dev/null || true; echo "$SANDBOX_INSTANCE_ID"'
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c 'source /etc/set-environment 2>/dev/null || true; echo "$SANDBOX_INSTANCE_ID"'

  # Run cleanup and capture output
  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-cleanup
  ')

  [[ "$OUTPUT" == *"Removed"* ]]
  [[ "$OUTPUT" != *"No sandboxes found to remove"* ]]
}

@test "sandbox-cleanup handles empty .sandboxes directory" {
  # Create empty .sandboxes directory
  mkdir -p "${TEST_PROJECT_DIR}/.sandboxes"

  # Run cleanup
  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-cleanup
  ')

  # Should report no sandboxes found
  [[ "$OUTPUT" == *"No sandboxes found to remove"* ]]
}

@test "sandbox-cleanup handles missing .sandboxes directory" {
  # Ensure .sandboxes doesn't exist
  rm -rf "${TEST_PROJECT_DIR}/.sandboxes" || true

  # Run cleanup
  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-cleanup
  ')

  # Should report no sandboxes found
  [[ "$OUTPUT" == *"No sandboxes found"* ]]
}
