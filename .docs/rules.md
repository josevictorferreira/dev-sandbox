# Project-Specific Rules & Lessons

> Read this before implementing. Updated after each session.

---

### Nix bash heredocs: avoid complex quote escaping
**Lesson:** When generating bash in Nix `writeShellScriptBin`, use double-quotes with `\$` escaping. Avoid `lib.replaceStrings` for quote escaping—it creates unreadable, error-prone code.
**Context:** First tmux module attempt had 45+ LSP errors from nested quote escaping. Simpler approach: `"cd \"$DIR\" && command"` with escaped `$` as `\$`.
**Verify:** `lsp_diagnostics` returns 0 errors after writing Nix files with embedded bash.

### Test Nix modules with explicit config, not empty attrs
**Lesson:** When testing modules with `nix-instantiate --eval`, always provide realistic config with all expected keys. Empty `config = {}` can cause infinite recursion on `or` defaults.
**Context:** `config.panes or [...]` with empty config caused stack overflow. Use `config = { panes = [...]; }`.
**Verify:** `nix-instantiate --eval --strict -E 'import ./module.nix { ... config = { realistic = "values"; }; }'`

### Linters require nix develop environment
**Lesson:** `statix` and `deadnix` are only in PATH inside `nix develop`. Run as `nix develop --command statix check`.
**Context:** Direct `statix check` fails with "command not found" outside devShell.
**Verify:** `nix develop --command statix check` exits 0.

### New modules need mkSandbox + flake.nix updates
**Lesson:** Adding new optional features to mkSandbox requires: (1) add param with default, (2) conditionally add to buildInputs, (3) update flake.nix mkSandbox signature to pass param through.
**Context:** Tmux integration required coordinated changes to lib/mkSandbox.nix param list + buildInputs + flake.nix signature.
**Verify:** `nix flake check` passes after adding new mkSandbox param.
