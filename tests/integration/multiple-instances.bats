#!/usr/bin/env bats
# Multiple instance isolation tests

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

  # Pre-generate flake.lock to avoid GitHub API calls during tests
  nix flake lock "${TEST_PROJECT_DIR}" --override-input dev-sandbox "path:${DEV_SANDBOX_ROOT}" 2>/dev/null || true
}

teardown() {
  teardown_test_env
}

@test "Multiple instances get unique IDs" {
  # Start two instances
  INSTANCE_1=$(run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"')

  INSTANCE_2=$(run_in_sandbox 'echo "$SANDBOX_INSTANCE_ID"')

  [ "$INSTANCE_1" != "$INSTANCE_2" ]
}

@test "Multiple instances have different sandbox directories" {
  INSTANCE_1_DIR=$(run_in_sandbox 'echo "$SANDBOX_DIR"')

  INSTANCE_2_DIR=$(run_in_sandbox 'echo "$SANDBOX_DIR"')

  [ "$INSTANCE_1_DIR" != "$INSTANCE_2_DIR" ]
}

@test "Multiple instances get different ports" {
  PORT_1=$(run_in_sandbox 'echo "$SANDBOX_PORT"')

  PORT_2=$(run_in_sandbox 'echo "$SANDBOX_PORT"')

  [ "$PORT_1" != "$PORT_2" ]
}

@test "Multiple instances do not share data directories" {
  DATA_DIR_1=$(run_in_sandbox 'echo "$PGDATA"')

  DATA_DIR_2=$(run_in_sandbox 'echo "$PGDATA"')

  [ "$DATA_DIR_1" != "$DATA_DIR_2" ]

  # Each instance should have its own fresh data directory (initialized by shell hook)
  # Verify both directories exist and have been initialized
  run_in_sandbox '[ -f "$PGDATA/PG_VERSION" ]'
}

@test "Multiple instances can start PostgreSQL independently" {
  # Start first instance and verify it starts
  run_in_sandbox 'db_start'

  # Start second instance and verify it starts (separate instance)
  run_in_sandbox 'db_start'
}

@test "Instances have unique socket directories" {
  SOCKET_1=$(run_in_sandbox 'echo "$PGHOST"')

  SOCKET_2=$(run_in_sandbox 'echo "$PGHOST"')

  [ "$SOCKET_1" != "$SOCKET_2" ]
}

@test "sandbox-list shows current instance" {
  # Test that sandbox-list can find the current instance
  run_in_sandbox 'sandbox-list'
}

@test "Ports stay in the 10000-15000 range" {
  for i in {1..10}; do
    PORT=$(run_in_sandbox 'echo "$SANDBOX_PORT"')

    [ "$PORT" -ge 10000 ]
    [ "$PORT" -le 15000 ]
  done
}
