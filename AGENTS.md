# PROJECT KNOWLEDGE BASE

**Generated:** 2025-01-16
**Branch:** main
**Language:** Nix

## OVERVIEW

Nix-based development sandbox library. Exposes `dev-sandbox.lib.mkSandbox` for creating isolated dev environments with services (PostgreSQL).

## STRUCTURE

```
./
├── flake.nix                    # Root entry, exports library
├── README.md                    # Project docs
├── .gitignore                   # Git exclusions
├── .statix.toml                 # Nix linter config
├── .deadnix.toml                # Dead code detector config
├── lib/
│   ├── mkSandbox.nix            # Core: builds devShell + scripts
│   ├── instance-id.nix          # Generates unique instance IDs
│   ├── ports.nix                # Port allocation logic
│   ├── services/
│   │   └── postgres.nix         # PostgreSQL service module
│   └── scripts/
│       └── default.nix          # Helper script generation
├── tests/
│   ├── unit/
│   │   └── default.nix          # Unit test entry
│   ├── integration/
│   │   ├── default.nix
│   │   ├── postgres.bats        # PostgreSQL integration tests
│   │   ├── instance-id.bats
│   │   └── sandbox.bats
│   ├── common/
│   │   └── default.nix
│   └── fixtures/
│       ├── rails-like/flake.nix # Example consumer
│       └── django-like/flake.nix
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add service | `lib/services/` | Add new `*.nix` module, import in `mkSandbox.nix` |
| Fix port allocation | `lib/ports.nix` | Handle port conflicts |
| Add integration test | `tests/integration/` | Create `*.bats` file, add to `default.nix` |
| Configure mkSandbox | `lib/mkSandbox.nix` | Modify args, service composition |
| Add instance generation | `lib/instance-id.nix` | Generate unique IDs for sandboxes |

## CONVENTIONS

- **Nix formatting**: `nix fmt` (nixpkgs-fmt)
- **Linting**: `statix check` (config: `.statix.toml`), `deadnix` (config: `.deadnix.toml`)
- **Naming**: snake_case for `.nix` files
- **Module pattern**: `let ... in { inherit ... ; }` for exports
- **Service modules**: Accept attrs, return service config

## ANTI-PATTERNS (THIS PROJECT)

- **Nix code in `mkSandbox.nix`**: Heavy use of `lib.concatStringsSep` and bash generation; prefer pure Nix where possible
- **Ignored lints**: `mkSandbox.nix` has `statix ignore` comments for `dead_code` and `unused_free_variable`; clean up when possible
- **Hidden state**: `.sandboxes/` directory is gitignored but holds runtime state; avoid committing

## UNIQUE STYLES

- **Service-oriented**: Modules in `lib/services/*.nix` compose into devShell
- **Bats integration tests**: `tests/integration/*.bats` test real service behavior
- **Fixture consumers**: `tests/fixtures/*/` show how downstream projects use the flake
- **Instance IDs**: `lib/instance-id.nix` generates unique IDs per sandbox

## COMMANDS

```bash
nix develop              # Enter devShell with all tools
nix flake check          # Run all checks (linter, tests)
cd tests/integration && bats *.bats   # Run integration tests manually
statix check             # Run Nix linter
deadnix                  # Detect dead code
```

## NOTES

- `mkSandbox` generates a hidden `.sandboxes/<id>/` directory for each dev environment
- PostgreSQL service creates a temporary database and exposes on random port (managed by `lib/ports.nix`)
- All tests use `bats` (Bash Automated Testing System)
- Fixtures demonstrate both Rails-like and Django-like project structures
