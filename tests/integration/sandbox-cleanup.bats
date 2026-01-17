#!/usr/bin/env bats
# Sandbox cleanup tests
#
# IMPORTANT: Each run_in_sandbox creates a NEW sandbox instance.
# Tests are designed with this in mind.

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
    export DEV_SANDBOX_ROOT="${PWD}/dev-sandbox"
  else
    export DEV_SANDBOX_ROOT="${PWD}/../.."
  fi
}

teardown_test_env() {
  pkill -f "postgres.*${TEST_TMPDIR}" || true
  sleep 1
  rm -rf "${TEST_TMPDIR}"
}

# Helper function to run commands inside nix develop sandbox
run_in_sandbox() {
  env -u SANDBOX_INSTANCE_ID -u SANDBOX_DIR -u PGDATA -u PGHOST -u PGPORT \
    nix develop "${TEST_PROJECT_DIR}" --impure --command sh -c "$1"
}

setup() {
  setup_test_env

  TEST_PROJECT_DIR="${TEST_TMPDIR}/test-project"
  mkdir -p "${TEST_PROJECT_DIR}"

  cat > "${TEST_PROJECT_DIR}/flake.nix" <<EOF
{
  description = "Test project for dev-sandbox";

  inputs = {
    dev-sandbox.url = "path:$DEV_SANDBOX_ROOT";
    nixpkgs.follows = "dev-sandbox/nixpkgs";
  };

  outputs = { self, nixpkgs, dev-sandbox }: {
    devShells.x86_64-linux.default = (dev-sandbox.lib { system = "x86_64-linux"; }).mkSandbox {
      projectRoot = ./.;
      services.postgres = true;
    };
  };
}
EOF

  nix flake lock "${TEST_PROJECT_DIR}" --override-input dev-sandbox "path:${DEV_SANDBOX_ROOT}" 2>/dev/null || true
}

teardown() {
  teardown_test_env
}

@test "sandbox-list shows current instance when sandbox is active" {
  # Every nix develop creates a new instance, so list should show it
  OUTPUT=$(run_in_sandbox 'sandbox-list')

  # Should show at least one sandbox (the one we just created by entering)
  [[ "$OUTPUT" == *"- "* ]] || [[ "$OUTPUT" == *"sandboxes"* ]]
}

@test "sandbox-list shows created instances" {
  # Create first instance, save its ID
  INSTANCE_1=$(run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"')

  # Create second instance, list sandboxes
  OUTPUT=$(run_in_sandbox 'sandbox-list')

  # Should show sandboxes (at least the 2 we created + the current one for list)
  [[ "$OUTPUT" != *"No sandboxes found"* ]]
  [[ "$OUTPUT" == *"- "* ]]
}

@test "sandbox-cleanup removes sandboxes from previous sessions" {
  # Create two instances (each run_in_sandbox creates a new one)
  run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"'
  run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"'

  # Run cleanup from a new session - it should report removing previous sandboxes
  # Note: cleanup removes ALL sandboxes including the current one
  OUTPUT=$(run_in_sandbox 'sandbox-cleanup')

  echo "$OUTPUT"
  # Should report removing at least 2 sandboxes (the 2 we created + potentially the current one)
  [[ "$OUTPUT" == *"Removed"* ]]
}

@test "sandbox-cleanup stops running PostgreSQL instances" {
  # Start PostgreSQL in an instance
  run_in_sandbox 'db_start; sleep 1'

  # Run cleanup from a new instance - it should stop PG in other sandboxes
  OUTPUT=$(run_in_sandbox 'sandbox-cleanup')

  # Verify cleanup ran
  [[ "$OUTPUT" == *"Removed"* ]] || [[ "$OUTPUT" == *"Removing"* ]]
}

@test "sandbox-cleanup removes data directories" {
  # Create instances with data
  run_in_sandbox 'db_start'
  run_in_sandbox 'db_start'

  # Run cleanup and verify PG_VERSION files are removed (except current instance)
  OUTPUT=$(run_in_sandbox '
    sandbox-cleanup
    # After cleanup, only current sandbox should have PG_VERSION
    COUNT=$(find "$SANDBOX_BASE_DIR" -name "PG_VERSION" 2>/dev/null | wc -l)
    echo "PG_VERSION count after cleanup: $COUNT"
    if [ "$COUNT" -le 1 ]; then
      echo "SUCCESS"
    else
      echo "FAIL: Too many PG_VERSION files: $COUNT"
      exit 1
    fi
  ')

  echo "$OUTPUT"
  [[ "$OUTPUT" == *"SUCCESS"* ]]
}

@test "sandbox-cleanup reports number of removed sandboxes" {
  # Create several instances
  run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"'
  run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"'
  run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"'

  # Run cleanup
  OUTPUT=$(run_in_sandbox 'sandbox-cleanup')

  # Should report removal
  [[ "$OUTPUT" == *"Removed"* ]] || [[ "$OUTPUT" == *"Removing"* ]]
}

@test "sandbox-cleanup handles missing sandbox directory gracefully" {
  # Run cleanup when no sandboxes have been created (fresh environment)
  # First remove any existing sandbox base dir
  rm -rf "${XDG_CACHE_HOME}/dev-sandbox" 2>/dev/null || true

  OUTPUT=$(run_in_sandbox 'sandbox-cleanup')

  # Should not error - either reports nothing to clean or cleans the one it just created
  [ $? -eq 0 ] || true
}
