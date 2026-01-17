#!/usr/bin/env bats
# PostgreSQL lifecycle integration tests

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

# Helper function to run commands inside nix develop sandbox
# Returns output in $output and status in $status (bats convention)
# Usage: run_in_sandbox 'cmd1; cmd2; cmd3'
# Note: We unset outer sandbox env vars to prevent pollution, but use --keep-PATH
# to ensure nix develop --command properly sets up the environment
run_in_sandbox() {
  env -u SANDBOX_INSTANCE_ID -u SANDBOX_DIR -u PGDATA -u PGHOST -u PGPORT \
    nix develop "${TEST_PROJECT_DIR}" --impure --command sh -c "$1"
}

setup() {
  setup_test_env

  # Create a test project
  TEST_PROJECT_DIR="${TEST_TMPDIR}/test-project"
  mkdir -p "${TEST_PROJECT_DIR}"

  # Create a minimal flake.nix for test project
  cat > "${TEST_PROJECT_DIR}/flake.nix" <<ENDOFFILE
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
ENDOFFILE

  # Pre-generate flake.lock to avoid GitHub API calls during tests
  nix flake lock "${TEST_PROJECT_DIR}" --override-input dev-sandbox "path:${DEV_SANDBOX_ROOT}" 2>/dev/null || true
}

teardown_test_env() {
  pkill -f "postgres.*${TEST_TMPDIR}" || true
  sleep 1
  rm -rf "${TEST_TMPDIR}"
}

teardown() {
  teardown_test_env
}

@test "PostgreSQL initializes on first shell startup" {
  output=$(run_in_sandbox 'db_start; echo "SANDBOX_DIR=$SANDBOX_DIR"; if [ -f "$PGDATA/PG_VERSION" ]; then echo "PostgreSQL initialized successfully"; cat "$PGDATA/PG_VERSION"; else echo "ERROR: PG_VERSION not found"; exit 1; fi; db_stop')
  status=$?

  [ "$status" -eq 0 ]
  [[ "$output" == *"PostgreSQL initialized successfully"* ]]
}

@test "db_start boots PostgreSQL successfully" {
  output=$(run_in_sandbox 'echo "Starting PostgreSQL..."; db_start; echo "Checking status..."; if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then echo "PostgreSQL is running"; exit 0; else echo "PostgreSQL failed to start"; exit 1; fi' 2>&1)
  status=$?

  [ "$status" -eq 0 ]
  [[ "$output" == *"PostgreSQL is ready!"* ]]
}

@test "pg_isready succeeds after db_start" {
  output=$(run_in_sandbox 'db_start; pg_isready -h "$PGHOST" -p "$PGPORT" -t 10')
  status=$?

  [ "$status" -eq 0 ]
}

@test "db_stop stops PostgreSQL successfully" {
  output=$(run_in_sandbox 'db_start; db_stop; if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then echo "PostgreSQL is still running"; exit 1; else echo "PostgreSQL is stopped"; exit 0; fi')
  status=$?

  [ "$status" -eq 0 ]
}

@test "PostgreSQL can be restarted after stop" {
  output=$(run_in_sandbox 'db_start; pg_isready -h "$PGHOST" -p "$PGPORT" -t 10; db_stop; db_start; pg_isready -h "$PGHOST" -p "$PGPORT" -t 10; echo "PostgreSQL restarted successfully"')
  status=$?

  [ "$status" -eq 0 ]
  [[ "$output" == *"PostgreSQL restarted successfully"* ]]
}

@test "PostgreSQL environment variables are set correctly" {
  output=$(run_in_sandbox 'echo "PGPORT=$PGPORT"; echo "PGHOST=$PGHOST"; echo "PGUSER=$PGUSER"; echo "PGPASSWORD=$PGPASSWORD"; echo "PGDATA=$PGDATA"; echo "PGDATABASE=$PGDATABASE"')
  status=$?

  [ "$status" -eq 0 ]
  [[ "$output" == *"PGPORT="* ]]
  [[ "$output" == *"PGHOST="* ]]
  [[ "$output" == *"PGUSER=postgres"* ]]
  [[ "$output" == *"PGPASSWORD=postgres"* ]]
  [[ "$output" == *"PGDATA="* ]]
  [[ "$output" == *"PGDATABASE=postgres"* ]]
}

@test "sandbox-up is an alias for db_start" {
  output=$(run_in_sandbox 'sandbox-up; pg_isready -h "$PGHOST" -p "$PGPORT" -t 10')
  status=$?

  [ "$status" -eq 0 ]
}

@test "sandbox-down is an alias for db_stop" {
  output=$(run_in_sandbox 'sandbox-up; sandbox-down; if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then exit 1; else exit 0; fi')
  status=$?

  [ "$status" -eq 0 ]
}
