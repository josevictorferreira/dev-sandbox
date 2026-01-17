# dev-sandbox

**Production-quality Nix flake library for isolated developer sandboxes**

A stack-agnostic, instance-isolated development environment system. Think "docker-compose for development — but fully Nix-native, deterministic, and instance-isolated."

## Philosophy

- **Isolation First**: Each shell instance has its own isolated state, ports, and services
- **Deterministic but Flexible**: Same project always gets same base ports; parallel shells offset automatically
- **Stack Agnostic**: No assumptions about frameworks (Rails, Django, Node, etc.)
- **Nix-Native**: No Docker, no VMs, just pure Nix
- **Zero Global State**: Everything lives under `.sandboxes/<instance-id>/`

## 🚀 Getting Started

Follow these steps to add `dev-sandbox` to your project.

### 1. Add to `flake.nix`

Add the input and configure your `devShell` using `mkSandbox`.

```nix
{
  description = "My Project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    
    # Add dev-sandbox input
    dev-sandbox.url = "github:your-org/dev-sandbox";
    dev-sandbox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, dev-sandbox, ... }:
    let
      system = "x86_64-linux"; # Adjust for your system (e.g., aarch64-darwin)
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = dev-sandbox.lib.${system}.mkSandbox {
        projectRoot = ./.;
        
        # Enable services
        services = { 
          postgres = true; 
        };
        
        # Add project packages
        packages = with pkgs; [ 
          nodejs_20
          yarn
          postgresql_16 # Client tools
        ];
        
        # Set environment variables
        env = { 
          NODE_ENV = "development";
          # DB vars like PGPORT are auto-injected
        };
        
        # Optional: Run setup commands
        shellHook = ''
          echo "🚀 Dev environment ready!"
          echo "DB running on port $PGPORT"
        '';
      };
    };
}
```

### 2. Enter the Sandbox

```bash
nix develop
```

This will:
1. Generate a unique instance ID
2. Allocate isolated ports (avoiding conflicts)
3. Create a private data directory in `.sandboxes/<id>`
4. Set environment variables (`PGPORT`, `PGDATA`, etc.)

### 3. Control Services

Manage your isolated services with built-in commands:

```bash
sandbox-up      # Start all services (Postgres, etc.)
sandbox-down    # Stop all services
sandbox-status  # Check status and ports
sandbox-cleanup # Remove stale sandboxes
```

---

## Usage Examples

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

## How It Works

1. **Instance ID**: Generated at shell startup from project path + timestamp + random
2. **Port Allocation**: Hash project → base port 10000-10500 → offset by instance ID
3. **State Directory**: All service data under `.sandboxes/<instance-id>/`
4. **Isolation**: Multiple shells can run side-by-side without port conflicts

## API Reference

### `lib.mkSandbox`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `projectRoot` | `path` | **Required** | Project root directory (use `./.`) |
| `services` | `attrs` | `{ postgres = true; }` | Services to enable |
| `packages` | `list` | `[ ]` | Additional packages to install |
| `env` | `attrs` | `{ }` | Environment variables to set |
| `shellHook` | `string` | `""` | Shell hook to run after setup |
| `postgresVersion` | `package` | `pkgs.postgresql_16` | PostgreSQL package to use |

### Environment Variables

Automatically injected when services are enabled:

- `SANDBOX_INSTANCE_ID`: Unique instance identifier
- `SANDBOX_DIR`: Sandbox state directory
- `SANDBOX_PORT`: PostgreSQL port for this instance
- `PGPORT`: PostgreSQL port
- `PGHOST`: PostgreSQL socket directory
- `PGUSER`: PostgreSQL user (postgres)
- `PGPASSWORD`: PostgreSQL password (postgres)
- `PGDATA`: PostgreSQL data directory

## Development

```bash
# Enter development shell
nix develop

# Run checks
nix flake check
```

## License

MIT
