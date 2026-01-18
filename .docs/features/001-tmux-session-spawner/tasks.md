# Tasks: Tmux Session Spawner

> Implementation checklist derived from `plan.md`
> **Rule**: Each phase must pass all tests + linting before proceeding to next phase.

---

## Phase 1: Core Tmux Module

**Goal**: Create `lib/tmux/default.nix` with session spawning logic and smart defaults.

### Implementation

- [x] Create `lib/tmux/default.nix` module structure
  - Accept `{ lib, pkgs, config }` parameters
  - Apply smart defaults: `sessionName = null` (auto-detect), `panes = [{ command = "$SHELL"; }]`, `layout = "tiled"`, `subpath = ""`
- [x] Implement session name auto-detection logic
  - Git repo name via `git rev-parse --show-toplevel | xargs basename`
  - Fallback to `basename $PWD`
- [x] Implement session ID auto-increment logic
  - Parse existing sessions via `tmux list-sessions -F '#{session_name}'`
  - Extract IDs matching pattern `{sessionName} #N`
  - Calculate `MAX_ID + 1` for next session
- [x] Generate `sandbox-spawn` script
  - Create detached session with `tmux new-session -d -s "$SESSION_NAME"`
  - Support explicit ID argument: `sandbox-spawn 5`
  - Split panes and run `nix develop --command` for each pane config
  - Apply configured layout via `tmux select-layout`
  - Handle attach vs switch-client based on `$TMUX` env var
- [x] Implement pane delay support (`delay = N` seconds before command)

### Testing

- [x] Create `tests/integration/tmux.bats` with basic spawn test
  - Test: `sandbox-spawn` creates session with auto-ID `#1`
  - Test: `sandbox-spawn 5` creates session with explicit ID `#5`
- [x] Verify scripts work in isolation (manual: `nix-build` + run)

### Gate

- [x] `nix flake check` passes
- [x] `statix check` passes (no linting offenses)
- [x] `deadnix` passes (no dead code)
- [x] All existing integration tests still pass

---

## Phase 2: Session Management Commands

**Goal**: Add fzf-based picker and session lifecycle commands.

### Implementation

- [x] Add `sandbox-pick` script to `lib/tmux/default.nix`
  - Filter sessions matching `^{sessionName} #` pattern
  - Use fzf for selection (`--prompt`, `--height=40%`, `--reverse`, `--border`)
  - Handle empty session list gracefully
  - Attach or switch-client based on `$TMUX`
- [x] Add `sandbox-sessions` script
  - List active sandbox sessions with window count and creation time
  - Filter to only matching sessions
- [x] Add `sandbox-kill` script
  - Accept optional explicit ID: `sandbox-kill 1`
  - fzf picker when no ID provided
  - Kill via `tmux kill-session -t`

### Testing

- [x] Add tests to `tests/integration/tmux.bats`
  - Test: `sandbox-sessions` lists only sandbox sessions (not unrelated tmux sessions)
  - Test: `sandbox-kill 1` kills specific session
  - Test: `sandbox-pick` exits gracefully when no sessions exist

### Gate

- [x] `nix flake check` passes
- [x] `statix check` passes
- [x] `deadnix` passes
- [x] All integration tests pass (including new tmux tests)

---

## Phase 3: mkSandbox Integration

**Goal**: Wire tmux module into `mkSandbox.nix` and expose via flake API.

### Implementation

- [x] Update `lib/mkSandbox.nix`
  - Add `tmux ? { enable = false; }` parameter
  - Apply smart defaults to tmux config (`sessionName`, `panes`, `layout`, `subpath`)
  - Import `lib/tmux/default.nix` module
  - Conditionally add tmux scripts to `buildInputs` when `tmux.enable = true`
  - Add `pkgs.tmux` and `pkgs.fzf` to `buildInputs` when enabled
- [x] Update `flake.nix` `mkSandbox` signature
  - Add `tmux ? { enable = false; }` to parameter list

### Testing [ASYNC: Can run parallel with Phase 3 Implementation]

- [x] Update `tests/fixtures/rails-like/flake.nix` with tmux example config
  - Enable `tmux.enable = true`
  - Add sample pane config for verification
- [x] Add integration test: entering `nix develop` with `tmux.enable = true` exposes commands
- [x] Add integration test: `tmux.enable = false` (or omitted) does NOT expose tmux commands

### Gate

- [x] `nix flake check` passes
- [x] `statix check` passes
- [x] `deadnix` passes
- [x] All integration tests pass
- [x] Backward compatibility verified: existing fixtures without tmux config still work

---

## Phase 4: Documentation

**Goal**: Update README with tmux usage, finalize integration tests.

### Implementation [ASYNC: README and Tests can be written in parallel]

- [x] Update `README.md`
  - Add "Tmux Sessions (Optional)" section
  - Document zero-config usage (`tmux.enable = true`)
  - Document full config options (`sessionName`, `panes`, `layout`, `subpath`)
  - Document all commands: `sandbox-spawn`, `sandbox-pick`, `sandbox-sessions`, `sandbox-kill`
  - Add examples: zero-config and power-user journeys
- [x] Update API Reference table in README
  - Add `tmux` parameter with type `attrs` and default `{ enable = false; }`

### Testing

- [x] Finalize `tests/integration/tmux.bats`
  - Ensure all edge cases covered (no sessions, multiple sessions, explicit ID)
  - Test layout application
  - Test subpath configuration (if applicable)
- [x] Update `tests/fixtures/django-like/flake.nix` with alternative tmux config (optional)

### Gate

- [x] `nix flake check` passes
- [x] `statix check` passes
- [x] `deadnix` passes
- [x] All integration tests pass
- [x] README renders correctly (no broken markdown)
- [x] Manual smoke test: Full user journey in fixture project

---

## Async Opportunities Summary

| Phase | Task | Can Run Async With |
|-------|------|-------------------|
| 3 | Testing (fixture updates) | Phase 3 Implementation |
| 4 | README updates | Phase 4 Testing |
| 4 | `django-like` fixture | Phase 4 README updates |

---

## Final Verification Checklist

- [x] All phases complete
- [x] `nix flake check` passes
- [x] `statix check` passes (0 offenses)
- [x] `deadnix` passes (0 dead code)
- [x] All `tests/integration/*.bats` pass
- [x] Backward compatibility: projects without `tmux` config unaffected
- [x] Feature complete per `plan.md` specification
