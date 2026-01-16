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

  cat > "${TEST_PROJECT_DIR}/flake.nix" << 'EOF'
{
  description = "Test project for dev-sandbox";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    dev-sandbox.url = "path:./dev-sandbox";
  };

  outputs = { self, nixpkgs, dev-sandbox }: {
    devShells.x86_64-linux.default = dev-sandbox.lib.x86_64-linux.mkSandbox {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
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

@test "Multiple instances get unique IDs" {
  # Start two instances
  INSTANCE_1=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
  ')

  INSTANCE_2=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
  ')

  [ "$INSTANCE_1" != "$INSTANCE_2" ]
}

@test "Multiple instances have different sandbox directories" {
  INSTANCE_1_DIR=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_DIR"
  ')

  INSTANCE_2_DIR=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_DIR"
  ')

  [ "$INSTANCE_1_DIR" != "$INSTANCE_2_DIR" ]
}

@test "Multiple instances get different ports" {
  PORT_1=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_PORT"
  ')

  PORT_2=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_PORT"
  ')

  [ "$PORT_1" != "$PORT_2" ]
}

@test "Multiple instances do not share data directories" {
  DATA_DIR_1=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$PGDATA"
  ')

  DATA_DIR_2=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$PGDATA"
  ')

  [ "$DATA_DIR_1" != "$DATA_DIR_2" ]

  # Initialize first instance
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    db_start
  '

  # Second instance should have fresh data (no PG_VERSION yet)
  RUN=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    if [ -f "$PGDATA/PG_VERSION" ]; then
      echo "already_exists"
    else
      echo "fresh"
    fi
  ')

  [ "$RUN" = "fresh" ]
}

@test "Multiple instances can run simultaneously" {
  # Start first instance
  PORT_1=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    db_start
    echo "$PGPORT"
  ')

  # Start second instance (in background to allow parallel execution)
  PORT_2=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    db_start
    echo "$PGPORT"
  ')

  [ "$PORT_1" != "$PORT_2" ]

  # Both should be running
  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    pg_isready -p "'"$PORT_1"'" -t 5
  '

  nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    pg_isready -p "'"$PORT_2"'" -t 5
  '
}

@test "Instances have unique socket directories" {
  SOCKET_1=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$PGHOST"
  ')

  SOCKET_2=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$PGHOST"
  ')

  [ "$SOCKET_1" != "$SOCKET_2" ]
}

@test "sandbox-list shows all instances" {
  INSTANCE_1=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
  ')

  INSTANCE_2=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    echo "$SANDBOX_INSTANCE_ID"
  ')

  OUTPUT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
    source /etc/set-environment 2>/dev/null || true
    sandbox-list
  ')

  [[ "$OUTPUT" == *"$INSTANCE_1"* ]]
  [[ "$OUTPUT" == *"$INSTANCE_2"* ]]
}

@test "Ports stay in the 10000-10500 range" {
  for i in {1..10}; do
    PORT=$(nix develop --impure "${TEST_PROJECT_DIR}" --command bash -c '
      source /etc/set-environment 2>/dev/null || true
      echo "$SANDBOX_PORT"
    ')

    [ "$PORT" -ge 10000 ]
    [ "$PORT" -le 10500 ]
  done
}
