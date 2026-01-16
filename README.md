# dev-sandbox

**Production-quality Nix flake library for isolated developer sandboxes**

A stack-agnostic, instance-isolated development environment system. Think "docker-compose for development — but fully Nix-native, deterministic, and instance-isolated."

## Philosophy

- **Isolation First**: Each shell instance has its own isolated state, ports, and services
- **Deterministic but Flexible**: Same project always gets same base ports; parallel shells offset automatically
- **Stack Agnostic**: No assumptions about frameworks (Rails, Django, Node, etc.)
- **Nix-Native**: No Docker, no VMs, just pure Nix
- **Zero Global State**: Everything lives under `.sandboxes/<instance-id>/`

## How It Works

1. **Instance ID**: Generated at shell startup from project path + timestamp + random
2. **Port Allocation**: Hash project → base port 10000-10500 → offset by instance ID
3. **State Directory**: All service data under `.sandboxes/<instance-id>/`
4. **Service Management**: Helper commands (`db_start`, `db_stop`, etc.) manage services
5. **Cleanup**: Automatic or manual cleanup removes stale instances

## Installation

Add dev-sandbox to your project's `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    dev-sandbox.url = "github:your-org/dev-sandbox";
    dev-sandbox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, dev-sandbox, ... }:
    let
      system = "x86_64-linux";
    in
    {
      devShells.${system}.default = dev-sandbox.lib.${system}.mkSandbox {
        projectRoot = ./.;
        # ...configuration
      };
    };
}
```

## Usage

### Minimal Example

```nix
devShells.default = dev-sandbox.lib.${system}.mkSandbox {
  projectRoot = ./.;
  services = { postgres = true; };
  packages = [ pkgs.nodejs ];
  env = { NODE_ENV = "development"; };
};
```

### Rails Example

```nix
devShells.default = dev-sandbox.lib.${system}.mkSandbox {
  projectRoot = ./.;
  services = { postgres = true; };
  packages = with pkgs; [ ruby_3_2 bundler ];
  env = {
    RAILS_ENV = "development";
    DATABASE_URL = "postgresql://postgres:postgres@localhost:$PGPORT/myapp_development";
  };
  postgresVersion = pkgs.postgresql_15;
};
```

### Django Example

```nix
devShells.default = dev-sandbox.lib.${system}.mkSandbox {
  projectRoot = ./.;
  services = { postgres = true; };
  packages = with pkgs; [ python311 poetry ];
  env = {
    DJANGO_SETTINGS_MODULE = "myproject.settings";
    DATABASE_URL = "postgresql://postgres:postgres@localhost:$PGPORT/myproject";
  };
  postgresVersion = pkgs.postgresql_16;
};
```

### Generic Application

```nix
devShells.default = dev-sandbox.lib.${system}.mkSandbox {
  projectRoot = ./.;
  services = { postgres = true; };
  packages = with pkgs; [ go gopls ];
  env = {
    DB_HOST = "localhost";
    DB_PORT = "$PGPORT";
  };
  shellHook = ''
    echo "Starting Go dev environment..."
  '';
};
```

## API

### `lib.mkSandbox :: { ... } -> devShell`

Creates an isolated development environment.

#### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `projectRoot` | `path` | **Required** | Project root directory (use `./.`) |
| `services` | `attrs` | `{ postgres = true; }` | Services to enable (currently `postgres`) |
| `packages` | `list` | `[ ]` | Additional packages to install |
| `env` | `attrs` | `{ }` | Environment variables to set |
| `shellHook` | `string` | `""` | Shell hook to run after setup |
| `postgresVersion` | `package` | `pkgs.postgresql_16` | PostgreSQL package to use |

#### Available Commands

- `db_start`: Start PostgreSQL service
- `db_stop`: Stop PostgreSQL service
- `sandbox-up`: Start all services (alias for `db_start`)
- `sandbox-down`: Stop all services (alias for `db_stop`)
- `sandbox-status`: Show sandbox status and running services
- `sandbox-list`: List all sandbox instances
- `sandbox-cleanup`: Clean up stale sandboxes

#### Environment Variables

When PostgreSQL is enabled, these are automatically set:

- `SANDBOX_INSTANCE_ID`: Unique instance identifier
- `SANDBOX_DIR`: Sandbox state directory
- `SANDBOX_PORT`: PostgreSQL port for this instance
- `PGPORT`: PostgreSQL port
- `PGHOST`: PostgreSQL socket directory
- `PGUSER`: PostgreSQL user (postgres)
- `PGPASSWORD`: PostgreSQL password (postgres)
- `PGDATA`: PostgreSQL data directory
- `PGDATABASE`: Default database (postgres)

## Isolation Model

Each sandbox instance has:
- Unique instance ID (20 hex chars)
- Separate PostgreSQL data directory
- Separate Unix socket directory
- Separate log directory
- Unique port (10000-10500 range)

Multiple developers can run parallel shells without conflicts.

```
myproject/
└─ .sandboxes/
   ├─ a1b2c3d4e5f6g7h8i9j0/  # Instance 1
   │  ├─ postgres/
   │  │  ├─ data/
   │  │  ├─ socket/
   │  │  └─ log/
   │  └─ process-compose.yaml
   └─ k9l8m7n6o5p4q3r2s1t0/  # Instance 2
      └─ postgres/
         ├─ data/
         ├─ socket/
         └─ log/
```

## Port Allocation

Ports are:
1. Deterministic from project path (hash → base port)
2. Offset by instance ID (for parallel shells)
3. Confined to range 10000-10500

Example:
- Project A: hash 1234 → base port 10123
- Instance 0: port 10123
- Instance 1: port 10125 (offset by 2)
- Instance 2: port 10127

No global port conflicts. No Docker network overhead.

## Testing

Run all tests:

```bash
nix flake check
```

### Test Structure

- `tests/unit/`: Pure Nix unit tests (port allocation, instance ID logic)
- `tests/integration/`: Runtime shell tests (PostgreSQL lifecycle)
- `tests/fixtures/`: Consumer examples (Rails-like, Django-like)

## Development

```bash
# Enter development shell
nix develop

# Format code
nixpkgs-fmt .

# Lint code
statix check .
deadnix -f .

# Run checks
nix flake check
```

## Guarantees

✅ **Isolation**: Concurrent shells never share state
✅ **Determinism**: Same project → same base port always
✅ **Cleanup**: Stale sandboxes can be cleaned up safely
✅ **No Assumptions**: Works with any stack (Rails, Django, Node, Go, etc.)
✅ **Nix-Native**: No Docker, no VMs, pure Nix
✅ **Cross-Platform**: Linux and macOS support

## Non-Goals

❌ **Framework-Specific Tools**: Not a Rails/Django/Node manager
❌ **Migrations**: Does not run database migrations
❌ **Service Discovery**: Only PostgreSQL (extensible)
❌ **Cloud Support**: Development environments only

## License

MIT

## Contributing

Contributions welcome! Please:
1. Add tests for new features
2. Follow Nix best practices
3. Keep it stack-agnostic
4. Update documentation

## See Also

- [Nix Flakes](https://nixos.wiki/wiki/Flakes)
- [Nixpkgs](https://github.com/NixOS/nixpkgs)
- [process-compose](https://github.com/F1bonacc1/process-compose)
