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
ENDOFFILE
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
  # Start the dev shell (this will initialize PostgreSQL)
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
SCRIPT

  # Shell should start successfully
  [ "$status" -eq 0 ]

  # Should have an instance ID
  [ -n "$output" ]

  # Check that PostgreSQL data directory was created
  run ls "${TEST_PROJECT_DIR}/.sandboxes"
  [ "$status" -eq 0 ]

  # Check that PG_VERSION exists (indicates PostgreSQL was initialized)
  run find "${TEST_PROJECT_DIR}/.sandboxes" -name "PG_VERSION"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "db_start boots PostgreSQL successfully" {
  # Start the dev shell and run db_start
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    echo "Starting PostgreSQL..."
    db_start

    echo "Checking status..."
    if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
      echo "PostgreSQL is running"
      exit 0
    else
      echo "PostgreSQL failed to start"
      exit 1
    fi
SCRIPT

  # Should start successfully
  [ "$status" -eq 0 ]
  [[ "$output" == *"PostgreSQL is ready!"* ]]
}

@test "pg_isready succeeds after db_start" {
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    # Start PostgreSQL
    db_start

    # Wait for PostgreSQL to be ready using pg_isready
    pg_isready -h "$PGHOST" -p "$PGPORT" -t 10
SCRIPT

  [ "$status" -eq 0 ]
}

@test "db_stop stops PostgreSQL successfully" {
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    # Start PostgreSQL
    db_start

    # Stop PostgreSQL
    db_stop

    # Verify it's stopped
    if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
      echo "PostgreSQL is still running"
      exit 1
    else
      echo "PostgreSQL is stopped"
      exit 0
    fi
SCRIPT

  [ "$status" -eq 0 ]
}

@test "PostgreSQL can be restarted after stop" {
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    # Start PostgreSQL
    db_start
    pg_isready -h "$PGHOST" -p "$PGPORT" -t 10

    # Stop PostgreSQL
    db_stop

    # Start again
    db_start
    pg_isready -h "$PGHOST" -p "$PGPORT" -t 10

    echo "PostgreSQL restarted successfully"
SCRIPT

  [ "$status" -eq 0 ]
  [[ "$output" == *"PostgreSQL restarted successfully"* ]]
}

@test "PostgreSQL environment variables are set correctly" {
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    echo "PGPORT=$PGPORT"
    echo "PGHOST=$PGHOST"
    echo "PGUSER=$PGUSER"
    echo "PGPASSWORD=$PGPASSWORD"
    echo "PGDATA=$PGDATA"
    echo "PGDATABASE=$PGDATABASE"
SCRIPT

  [ "$status" -eq 0 ]
  [[ "$output" == *"PGPORT="* ]]
  [[ "$output" == *"PGHOST="* ]]
  [[ "$output" == *"PGUSER=postgres"* ]]
  [[ "$output" == *"PGPASSWORD=postgres"* ]]
  [[ "$output" == *"PGDATA="* ]]
  [[ "$output" == *"PGDATABASE=postgres"* ]]
}

@test "sandbox-up is an alias for db_start" {
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    # Use sandbox-up
    sandbox-up

    # Verify PostgreSQL is running
    pg_isready -h "$PGHOST" -p "$PGPORT" -t 10
SCRIPT

  [ "$status" -eq 0 ]
}

@test "sandbox-down is an alias for db_stop" {
  run nix develop "${TEST_PROJECT_DIR}" --impure --command bash <<'SCRIPT'
    source /etc/set-environment 2>/dev/null || true

    # Start with sandbox-up
    sandbox-up

    # Stop with sandbox-down
    sandbox-down

    # Verify it's stopped
    if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
      exit 1
    else
      exit 0
    fi
SCRIPT

  [ "$status" -eq 0 ]
}
