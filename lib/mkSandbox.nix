# Main library function: mkSandbox

{ lib
, pkgs
, projectRoot
, services ? { postgres = true; }
, packages ? [ ]
, env ? { }
, shellHook ? ""
, postgresVersion ? pkgs.postgresql_16
}:

let
  # Import sub-modules
  instanceIdModule = import ./instance-id.nix { inherit lib; };

  # Generate instance ID at runtime
  instanceIdScript = instanceIdModule.generateInstanceIdScript pkgs;

  # Hash of project root for unique cache directory
  projectHash = builtins.hashString "sha256" (toString projectRoot);
  projectHashShort = builtins.substring 0 12 projectHash;

  # Shell hook that sets up the sandbox environment
  sandboxShellHook = ''
                {
                    # Generate unique instance ID
                    INSTANCE_ID=$(${instanceIdScript})
                    export SANDBOX_INSTANCE_ID="$INSTANCE_ID"

                # Use XDG cache directory for sandbox data (writable, persists across sessions)
                # Each project gets a unique subdirectory based on its hash
                SANDBOX_BASE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/dev-sandbox/${projectHashShort}"
                SANDBOX_DIR="$SANDBOX_BASE_DIR/$INSTANCE_ID"
                export SANDBOX_DIR
                export SANDBOX_BASE_DIR

                    # Derive port: use instance ID for unique port allocation
                    # Use last 8 hex chars for uniqueness (random portion)
                    ID_LEN=''${#INSTANCE_ID}
                    LAST_8=''${INSTANCE_ID: -8}
                    INSTANCE_NUM=$((16#$LAST_8))
                    # Keep in range [10000-14999] (5000 ports to reduce collision)
                    PORT=$((10000 + INSTANCE_NUM % 5000))
                    export SANDBOX_PORT="$PORT"

                    # Setup directories
                    mkdir -p "$SANDBOX_DIR"

                # PostgreSQL paths and configuration (conditional)
                if [ "x${toString services.postgres}" = "x1" ]; then
                      PG_DATA_DIR="$SANDBOX_DIR/postgres/data"
                      # Use short socket path to avoid Unix socket path length limit (108 chars)
                      # Include full instance ID to ensure uniqueness
                      PG_SOCKET_DIR="/tmp/pg-$INSTANCE_ID"
                      PG_LOG_DIR="$SANDBOX_DIR/postgres/log"

                      mkdir -p "$PG_DATA_DIR" "$PG_SOCKET_DIR" "$PG_LOG_DIR"

                      # PostgreSQL environment (all must be exported for db_start)
                      export PGPORT="$PORT"
                      export PGHOST="$PG_SOCKET_DIR"
                      export PGUSER="postgres"
                      export PGPASSWORD="postgres"
                      export PGDATA="$PG_DATA_DIR"
                      export PGDATABASE="postgres"
                      export PG_LOG_DIR

                      # Generate PostgreSQL config
                      cat > "$SANDBOX_DIR/postgres/postgresql.conf" << EOF
    port = $PGPORT
    max_connections = 100
    shared_buffers = 128MB
    unix_socket_directories = '$PGHOST'
    logging_collector = on
    log_directory = '$PG_LOG_DIR'
    log_filename = 'postgresql.log'
    log_rotation_age = 1d
    log_rotation_size = 100MB
    effective_cache_size = 256MB
    maintenance_work_mem = 64MB
    checkpoint_completion_target = 0.9
    wal_buffers = 16MB
    default_statistics_target = 100
    random_page_cost = 1.1
    EOF

                      cat > "$SANDBOX_DIR/postgres/pg_hba.conf" << 'EOF'
    local   all             all                                     md5
    host    all             all             127.0.0.1/32            md5
    host    all             all             ::1/128                 md5
    EOF

                      # Initialize PostgreSQL if needed
                      if [ ! -f "$PG_DATA_DIR/PG_VERSION" ]; then
                        echo "Initializing PostgreSQL..."
                        ${postgresVersion}/bin/initdb \
                          -D "$PG_DATA_DIR" \
                          --auth=md5 \
                          --username=postgres \
                          --pwfile=<(echo "postgres")
                      fi
                    fi

                    # Display sandbox info
                    echo ""
                    echo "=========================================="
                    echo "Sandbox Instance: $INSTANCE_ID"
                    echo "Sandbox Directory: $SANDBOX_DIR"
                    echo "=========================================="
                    echo ""
                } >&2

                    ${shellHook}

                    # Cleanup on exit
                    trap ''${SANDBOX_CLEANUP_TRAP:-} EXIT
  '';

  # Helper commands for the sandbox
  dbStart = pkgs.writeShellScriptBin "db_start" ''
    set -eo pipefail

    if [ -z "''${SANDBOX_INSTANCE_ID:-}" ]; then
      echo "Error: Not in a sandbox environment" >&2
      exit 1
    fi

    if [ -z "''${PGDATA:-}" ]; then
      echo "Error: PGDATA is not set. PostgreSQL service may not be enabled." >&2
      exit 1
    fi

    if [ -z "''${PG_LOG_DIR:-}" ]; then
      echo "Error: PG_LOG_DIR is not set." >&2
      exit 1
    fi

    if [ -z "''${SANDBOX_DIR:-}" ]; then
      echo "Error: SANDBOX_DIR is not set." >&2
      exit 1
    fi

    if ${postgresVersion}/bin/pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
      echo "PostgreSQL is already running" >&2
      exit 0
    fi

    echo "Starting PostgreSQL..." >&2
    ${postgresVersion}/bin/pg_ctl \
      -D "$PGDATA" \
      -l "$PG_LOG_DIR/postgresql.log" \
      -o "-c config_file=$SANDBOX_DIR/postgres/postgresql.conf" \
      -o "-c hba_file=$SANDBOX_DIR/postgres/pg_hba.conf" \
      start >&2

    echo "Waiting for PostgreSQL to be ready..." >&2
    ${postgresVersion}/bin/pg_isready \
      -h "$PGHOST" \
      -p "$PGPORT" \
      -t 30 >&2

    echo "PostgreSQL is ready!" >&2
  '';

  dbStop = pkgs.writeShellScriptBin "db_stop" ''
    set -eo pipefail

    if [ -z "''${SANDBOX_INSTANCE_ID:-}" ]; then
      echo "Error: Not in a sandbox environment"
      exit 1
    fi

    echo "Stopping PostgreSQL..."
    ${postgresVersion}/bin/pg_ctl \
      -D "$PGDATA" \
      stop -m fast

    echo "PostgreSQL stopped"
  '';

  sandboxUp = pkgs.writeShellScriptBin "sandbox-up" ''
    set -euo pipefail

    if [ -z "$SANDBOX_INSTANCE_ID" ]; then
      echo "Error: Not in a sandbox environment"
      exit 1
    fi

    # Use db_start for now (process-compose support can be added later)
    db_start
  '';

  sandboxDown = pkgs.writeShellScriptBin "sandbox-down" ''
    set -euo pipefail

    if [ -z "$SANDBOX_INSTANCE_ID" ]; then
      echo "Error: Not in a sandbox environment"
      exit 1
    fi

    db_stop
  '';

  sandboxStatus = pkgs.writeShellScriptBin "sandbox-status" ''
    set -euo pipefail

    if [ -z "$SANDBOX_INSTANCE_ID" ]; then
      echo "Error: Not in a sandbox environment"
      exit 1
    fi

    echo "Sandbox Instance: $SANDBOX_INSTANCE_ID"
    echo "Directory: $SANDBOX_DIR"
    echo ""

    if ${postgresVersion}/bin/pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
      echo "PostgreSQL: Running"
      echo "Port: $PGPORT"
      echo "Socket: $PGHOST"
    else
      echo "PostgreSQL: Stopped"
    fi
  '';

  sandboxList = pkgs.writeShellScriptBin "sandbox-list" ''
    set -euo pipefail

    # Use SANDBOX_BASE_DIR from environment if available, otherwise fallback to hardcoded path
    SANDBOXES_DIR="''${SANDBOX_BASE_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/dev-sandbox/${projectHashShort}}"

    if [ ! -d "$SANDBOXES_DIR" ]; then
      echo "No sandboxes found"
      exit 0
    fi

    echo "Available sandboxes:"
    echo ""

    for sandbox in "$SANDBOXES_DIR"/*; do
      if [ -d "$sandbox" ]; then
        INSTANCE_ID=$(basename "$sandbox")
        echo "  - $INSTANCE_ID"

        PGDATA="$sandbox/postgres/data"
        if ${postgresVersion}/bin/pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
          echo "    PostgreSQL: Running"
        else
          echo "    PostgreSQL: Stopped"
        fi

        echo ""
      fi
    done
  '';

  sandboxCleanup = pkgs.writeShellScriptBin "sandbox-cleanup" ''
    set -euo pipefail

    # Use SANDBOX_BASE_DIR from environment if available, otherwise fallback to hardcoded path
    SANDBOXES_DIR="''${SANDBOX_BASE_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/dev-sandbox/${projectHashShort}}"

    if [ ! -d "$SANDBOXES_DIR" ]; then
      echo "No sandboxes found"
      exit 0
    fi

    echo "Cleaning up stale sandboxes..."
    echo ""

    REMOVED=0

    for sandbox in "$SANDBOXES_DIR"/*; do
      if [ -d "$sandbox" ]; then
        INSTANCE_ID=$(basename "$sandbox")
        PGDATA="$sandbox/postgres/data"

        # Stop PostgreSQL if running
        if ${postgresVersion}/bin/pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
          echo "Stopping $INSTANCE_ID..."
          ${postgresVersion}/bin/pg_ctl -D "$PGDATA" stop -m fast
        fi

        echo "Removing $INSTANCE_ID..."
        rm -rf "$sandbox"
        REMOVED=$((REMOVED + 1))
      fi
    done

    if [ $REMOVED -eq 0 ]; then
      echo "No sandboxes found to remove"
    else
      echo "Removed $REMOVED sandbox(es)"
    fi
  '';

  # Build dev shell
  devShell = pkgs.mkShell {
    buildInputs = packages ++ [
      dbStart
      dbStop
      sandboxUp
      sandboxDown
      sandboxStatus
      sandboxList
      sandboxCleanup
      postgresVersion # PostgreSQL binaries (psql, pg_isready, etc.)
      pkgs.process-compose # Optional: for future process-compose integration
    ];

    shellHook = sandboxShellHook;

    # Merge user-provided environment with sandbox environment
    inherit env;
  };

in
{
  inherit devShell;
}
