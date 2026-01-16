# PostgreSQL service configuration for sandbox instances

{ pkgs }:

{ port
, dataDir
, socketDir
, logDir
, postgresPackage ? pkgs.postgresql_16
, postgresPassword ? "postgres"
}:

let
  # PostgreSQL configuration
  config = pkgs.writeText "postgresql.conf" ''
    # Port configuration
    port = ${toString port}
    max_connections = 100
    shared_buffers = 128MB

    # Socket configuration (use Unix socket for isolation)
    unix_socket_directories = '${socketDir}'

    # Logging
    logging_collector = on
    log_directory = '${logDir}'
    log_filename = 'postgresql.log'
    log_rotation_age = 1d
    log_rotation_size = 100MB

    # Performance tuning for development
    effective_cache_size = 256MB
    maintenance_work_mem = 64MB
    checkpoint_completion_target = 0.9
    wal_buffers = 16MB
    default_statistics_target = 100
    random_page_cost = 1.1

    # Development-friendly settings
    log_statement = 'all'
    log_duration = on
  '';

  # pg_hba.conf for local access (password required)
  hba = pkgs.writeText "pg_hba.conf" ''
    # TYPE  DATABASE        USER            ADDRESS                 METHOD
    local   all             all                                     md5
    host    all             all             127.0.0.1/32            md5
    host    all             all             ::1/128                 md5
  '';

  # Database initialization script (sets password)
  initScript = pkgs.writeText "init-postgres.sql" ''
    ALTER USER postgres WITH PASSWORD '${postgresPassword}';
  '';

  # Helper to initialize the database
  initdbScript = pkgs.writeShellScript "initdb" ''
    set -euo pipefail

    echo "Initializing PostgreSQL data directory..."
    rm -rf "${dataDir}"
    mkdir -p "${dataDir}" "${socketDir}" "${logDir}"

    ${postgresPackage}/bin/initdb \
      -D "${dataDir}" \
      --auth=md5 \
      --username=postgres \
      --pwfile=<(echo '${postgresPassword}')

    echo "PostgreSQL initialized successfully"
  '';

  # Start PostgreSQL
  startScript = pkgs.writeShellScript "start-postgres" ''
    set -euo pipefail

    # Initialize if not already done
    if [ ! -f "${dataDir}/PG_VERSION" ]; then
      ${initdbScript}
    fi

    # Start PostgreSQL in the background
    echo "Starting PostgreSQL on port ${toString port}..."
    ${postgresPackage}/bin/pg_ctl \
      -D "${dataDir}" \
      -l "${logDir}/postgresql.log" \
      -o "-c config_file=${config}" \
      -o "-c hba_file=${hba}" \
      start

    # Wait for PostgreSQL to be ready
    echo "Waiting for PostgreSQL to be ready..."
    ${postgresPackage}/bin/pg_isready \
      -h "${socketDir}" \
      -p ${toString port} \
      -t 30

    echo "PostgreSQL is ready!"
  '';

  # Stop PostgreSQL
  stopScript = pkgs.writeShellScript "stop-postgres" ''
    set -euo pipefail

    echo "Stopping PostgreSQL..."
    ${postgresPackage}/bin/pg_ctl \
      -D "${dataDir}" \
      stop -m fast

    echo "PostgreSQL stopped"
  '';

  # Restart PostgreSQL
  restartScript = pkgs.writeShellScript "restart-postgres" ''
    set -euo pipefail

    ${stopScript}
    ${startScript}
  '';

  # Check PostgreSQL status
  statusScript = pkgs.writeShellScript "status-postgres" ''
    set -euo pipefail

    if ${postgresPackage}/bin/pg_ctl -D "${dataDir}" status > /dev/null 2>&1; then
      echo "PostgreSQL is running"
      echo "Port: ${toString port}"
      echo "Socket: ${socketDir}"
      echo "Data: ${dataDir}"
      echo "Log: ${logDir}"
      exit 0
    else
      echo "PostgreSQL is not running"
      exit 1
    fi
  '';

  # Connect to PostgreSQL
  connectScript = pkgs.writeShellScript "connect-postgres" ''
    set -euo pipefail

    ${postgresPackage}/bin/psql \
      -h "${socketDir}" \
      -p ${toString port} \
      -U postgres \
      "$@"
  '';

in
{
  # Configuration files
  inherit config hba initScript;

  # Control scripts
  inherit initdbScript startScript stopScript restartScript statusScript connectScript;

  # Environment variables to export
  env = {
    PGPORT = toString port;
    PGHOST = socketDir;
    PGUSER = "postgres";
    PGPASSWORD = postgresPassword;
    PGDATA = dataDir;
    PGDATABASE = "postgres";
  };

  # Packages needed
  packages = [ postgresPackage ];

  # process-compose configuration for supervised mode
  processComposeConfig = {
    version = "0.5";
    processes.postgres = {
      command = "${postgresPackage}/bin/postgres -D ${dataDir} -c config_file=${config} -c hba_file=${hba} -k ${socketDir} -p ${toString port}";
      shutdown.command = "${postgresPackage}/bin/pg_ctl -D ${dataDir} stop -m fast";
      readiness_probe = {
        exec.command = "${postgresPackage}/bin/pg_isready -h ${socketDir} -p ${toString port}";
        initial_delay_seconds = 2;
        period_seconds = 1;
      };
    };
  };
}
