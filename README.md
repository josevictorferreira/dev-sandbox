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
    
    dev-sandbox.url = "github:josevictorferreira/dev-sandbox";
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
| `tmux` | `attrs` | `{ enable = false; }` | Tmux session spawner config |

### Tmux Session Spawner

Enable tmux integration to spawn consistent multi-pane sessions for your project:

```nix
devShells.default = dev-sandbox.lib.${system}.mkSandbox {
  projectRoot = ./.;
  services = { postgres = true; };
  packages = with pkgs; [ nodejs ];

  # Tmux configuration
  tmux = {
    enable = true;
    sessionName = null;  # Auto-detect from git repo or dirname
    panes = [
      { command = "nvim ."; }
      { command = "npm run dev"; delay = 2; }  # Wait 2s before running
      { command = "$SHELL"; }  # Plain shell
    ];
    layout = "main-horizontal";  # "tiled", "main-vertical", "even-horizontal", etc.
    subpath = "";  # Optional subdirectory to cd into
  };
};
```

#### Tmux Commands

When `tmux.enable = true`, these commands are available in your shell:

| Command | Description |
|---------|-------------|
| `sandbox-spawn` | Create new tmux session (auto-increments ID) |
| `sandbox-spawn 5` | Create session with explicit ID |
| `sandbox-pick` | fzf picker to switch between sandbox sessions |
| `sandbox-sessions` | List active sandbox sessions |
| `sandbox-kill` | Kill a sandbox session (fzf picker if no arg) |
| `sandbox-kill 3` | Kill session with ID 3 |

#### Tmux Config Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | `bool` | `false` | Enable tmux integration |
| `sessionName` | `string\|null` | `null` | Session name (null = auto-detect from git) |
| `panes` | `list` | `[{ command = "$SHELL"; }]` | Pane configurations |
| `layout` | `string` | `"tiled"` | Tmux layout (tiled, main-horizontal, etc.) |
| `subpath` | `string` | `""` | Subdirectory to cd into for all panes |

#### Pane Config

Each pane in the `panes` list accepts:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `command` | `string` | `"$SHELL"` | Command to run in the pane |
| `delay` | `int` | `0` | Seconds to wait before running command |

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
