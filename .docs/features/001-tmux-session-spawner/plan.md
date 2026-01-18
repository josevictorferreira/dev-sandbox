# Technical Implementation Plan: Tmux Session Spawner

## 1. Executive Summary

Add tmux-native session spawning to `dev-sandbox`. Single command `sandbox-spawn` creates isolated tmux sessions with configurable panes, auto-incrementing session IDs, and fzf-based picker. Library exposes `tmux` config in `mkSandbox` for declarative pane definitions.

**Design Philosophy**: Zero-config by default, progressive customization. `tmux.enable = true` is all you need.

## 2. Architecture & Design

### 2.1 Component Structure

```
lib/
├── mkSandbox.nix           # MODIFY: Add tmux config option, generate spawn script
├── tmux/
│   └── default.nix         # NEW: Tmux session management module
│       ├── session-spawner.nix   # Session creation logic
│       └── session-picker.nix    # fzf picker for existing sessions
├── instance-id.nix         # EXISTING: Reuse for session ID generation
└── scripts/
    └── default.nix         # EXISTING: May extend for tmux scripts
```

### 2.2 Data Models & State

**Zero-Config Default Philosophy**:

The simplest config should work out of the box:

```nix
mkSandbox {
  projectRoot = ./.;
  tmux.enable = true;  # That's it! Everything auto-configured.
}
```

**Smart Defaults** (all derived automatically):

| Option | Default Value | Derivation Logic |
|--------|---------------|------------------|
| `sessionName` | Git repo name or directory name | `git rev-parse --show-toplevel \| xargs basename` at runtime, fallback to `basename $PWD` |
| `panes` | `[{ command = "$SHELL"; }]` | Single pane with user's shell |
| `layout` | `"tiled"` | Works well for 1-4 panes |
| `subpath` | `""` | No subpath (project root) |

**Full Configuration Schema** (for power users):

```nix
# User-facing API in mkSandbox
mkSandbox {
  projectRoot = ./.;
  services.postgres = true;
  packages = [ ... ];
  
  # NEW: Tmux configuration
  tmux = {
    enable = true;                    # Required to enable tmux features
    
    # ALL BELOW ARE OPTIONAL - sensible defaults applied
    sessionName = "MyProject";        # Default: auto-detected from git/directory
    
    # Pane definitions - commands run inside nix develop
    panes = [
      { command = "nvim"; }                           # Just open editor
      { command = "db_start && rails console"; }      # Start DB + console
      { command = "bin/dev"; delay = 3; }             # Wait 3s before running
    ];
    
    layout = "tiled";                 # Default: "tiled", options: main-horizontal, main-vertical, even-horizontal, even-vertical
    
    # Optional: subpath for monorepos
    subpath = "backend";              # cd into subpath before nix develop
  };
}
```

**Runtime State**:
- Session naming: `{sessionName} #{SESSION_ID}` (e.g., "my-project #1")
- Session ID source of truth: Live tmux sessions via `tmux list-sessions`
- No persistent state files needed

### 2.3 Command Interface

| Command | Description |
|---------|-------------|
| `sandbox-spawn` | Create new tmux session with next available ID |
| `sandbox-spawn 5` | Create session with explicit ID |
| `sandbox-pick` | fzf picker to attach to existing session |
| `sandbox-sessions` | List active sandbox sessions |
| `sandbox-kill [ID]` | Kill specific session (or pick via fzf) |

**All commands available INSIDE `nix develop` when `tmux.enable = true`.**

## 3. Implementation Strategy

### Phase 1: Core Tmux Module

**Goal**: Create `lib/tmux/default.nix` with session creation logic and smart defaults.

**Key Changes**:
- `lib/tmux/default.nix`: Main module exposing `mkTmuxScripts`
- Generates `sandbox-spawn` script that:
  1. Auto-detects session name from git repo or directory (if not configured)
  2. Detects next available session ID from existing tmux sessions
  3. Creates new tmux session with configured name
  4. Splits into configured panes (default: single shell pane)
  5. Runs `nix develop --command <pane.command>` in each pane with delays
  6. Attaches to session (or switches if already in tmux)

**Implementation Details**:

```nix
# lib/tmux/default.nix
{ lib, pkgs, config }:
let
  # Config with smart defaults applied
  sessionNameConfigured = config.sessionName or null;  # null = auto-detect at runtime
  panes = config.panes or [{ command = "$SHELL"; }];   # Default: single shell pane
  layout = config.layout or "tiled";
  subpath = config.subpath or "";
  
  # Generate pane creation commands
  paneCommands = lib.imap0 (i: pane: 
    let
      delay = pane.delay or 0;
      cmd = pane.command or "$SHELL";
      # First pane is created with session, rest are splits
      splitCmd = if i == 0 then "" else "tmux split-window -t \"$SESSION_NAME\"";
      delayCmd = if delay > 0 then "sleep ${toString delay} && " else "";
    in
    ''
      ${splitCmd}
      tmux send-keys -t "$SESSION_NAME:0.${toString i}" "cd \"$PROJECT_DIR/${subpath}\" && nix develop --command $SHELL -c '${delayCmd}${cmd}'" Enter
    ''
  ) panes;
  
  # Session name derivation logic (runtime)
  sessionNameDerivation = ''
    # Auto-detect session name from git repo or directory
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
      SESSION_BASE=$(basename "$(git rev-parse --show-toplevel)")
    else
      SESSION_BASE=$(basename "$PWD")
    fi
  '';
  
  # If user configured a name, use it directly
  sessionNameScript = if sessionNameConfigured != null 
    then ''SESSION_BASE="${sessionNameConfigured}"''
    else sessionNameDerivation;
in
{
  spawnScript = pkgs.writeShellScriptBin "sandbox-spawn" ''
    set -euo pipefail
    
    PROJECT_DIR="$PWD"
    SUBPATH="${subpath}"
    
    # Determine session name (configured or auto-detected)
    ${sessionNameScript}
    
    # Get explicit ID or auto-detect next
    if [ -n "''${1:-}" ]; then
      SESSION_ID="$1"
    else
      # Extract existing IDs from session names matching pattern
      MAX_ID=0
      while IFS= read -r name; do
        # Match pattern: "SessionName #N"
        if [[ "$name" =~ ^"$SESSION_BASE"\ #([0-9]+)$ ]]; then
          ID="''${BASH_REMATCH[1]}"
          [ "$ID" -gt "$MAX_ID" ] && MAX_ID="$ID"
        fi
      done < <(${pkgs.tmux}/bin/tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
      SESSION_ID=$((MAX_ID + 1))
    fi
    
    SESSION_NAME="$SESSION_BASE #$SESSION_ID"
    export SESSION_ID SESSION_NAME
    
    echo "Creating session: $SESSION_NAME"
    
    # Create session (detached initially)
    ${pkgs.tmux}/bin/tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR/$SUBPATH"
    
    # Create panes and run commands
    ${lib.concatStringsSep "\n" paneCommands}
    
    # Apply layout
    ${pkgs.tmux}/bin/tmux select-layout -t "$SESSION_NAME" ${layout}
    
    # Attach or switch
    if [ -n "''${TMUX:-}" ]; then
      ${pkgs.tmux}/bin/tmux switch-client -t "$SESSION_NAME"
    else
      ${pkgs.tmux}/bin/tmux attach-session -t "$SESSION_NAME"
    fi
  '';
}
```

**Verification**:
- `nix develop` → `sandbox-spawn` → Creates "project-name #1" (auto-detected)
- `sandbox-spawn 5` → Creates session with ID 5
- Running twice auto-increments (session #1, #2)
- Zero-config works: just `tmux.enable = true` → single shell pane session

---

### Phase 2: Session Picker & Management

**Goal**: Add fzf-based picker and session management commands.

**Key Changes**:
- `sandbox-pick`: fzf picker filtering only sandbox sessions
- `sandbox-sessions`: List active sandbox sessions with status
- `sandbox-kill`: Kill session by ID or via fzf

**Implementation Details**:

```nix
# Session name pattern needs runtime detection for picker/kill
# We store the session base in an env var during spawn, or re-detect

pickScript = pkgs.writeShellScriptBin "sandbox-pick" ''
  set -euo pipefail
  
  # Auto-detect session base (same logic as spawn)
  ${sessionNameScript}
  
  PATTERN="^$SESSION_BASE #"
  
  SESSIONS=$(${pkgs.tmux}/bin/tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "$PATTERN" || true)
  
  if [ -z "$SESSIONS" ]; then
    echo "No sandbox sessions found for '$SESSION_BASE'. Use 'sandbox-spawn' to create one."
    exit 0
  fi
  
  SELECTED=$(echo "$SESSIONS" | ${pkgs.fzf}/bin/fzf \
    --prompt="sandbox session> " \
    --height=40% \
    --reverse \
    --border \
    --header="Select a sandbox session")
  
  [ -z "$SELECTED" ] && exit 0
  
  if [ -n "''${TMUX:-}" ]; then
    ${pkgs.tmux}/bin/tmux switch-client -t "$SELECTED"
  else
    ${pkgs.tmux}/bin/tmux attach-session -t "$SELECTED"
  fi
'';

sessionsScript = pkgs.writeShellScriptBin "sandbox-sessions" ''
  set -euo pipefail
  
  ${sessionNameScript}
  
  PATTERN="^$SESSION_BASE #"
  
  echo "Active Sandbox Sessions ($SESSION_BASE):"
  echo ""
  
  ${pkgs.tmux}/bin/tmux list-sessions -F '#{session_name} (#{session_windows} windows, created #{session_created_string})' 2>/dev/null \
    | grep -E "$PATTERN" || echo "  (none)"
'';

killScript = pkgs.writeShellScriptBin "sandbox-kill" ''
  set -euo pipefail
  
  ${sessionNameScript}
  
  PATTERN="^$SESSION_BASE #"
  
  if [ -n "''${1:-}" ]; then
    TARGET="$SESSION_BASE #$1"
  else
    SESSIONS=$(${pkgs.tmux}/bin/tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "$PATTERN" || true)
    
    if [ -z "$SESSIONS" ]; then
      echo "No sandbox sessions to kill."
      exit 0
    fi
    
    TARGET=$(echo "$SESSIONS" | ${pkgs.fzf}/bin/fzf \
      --prompt="kill session> " \
      --height=40% \
      --reverse \
      --border \
      --header="Select session to kill")
  fi
  
  [ -z "$TARGET" ] && exit 0
  
  ${pkgs.tmux}/bin/tmux kill-session -t "$TARGET"
  echo "Killed: $TARGET"
'';
```

**Verification**:
- `sandbox-pick` with 2+ sessions → fzf appears, selection attaches
- `sandbox-sessions` → Shows list with window count
- `sandbox-kill 1` → Kills session #1

---

### Phase 3: mkSandbox Integration

**Goal**: Wire tmux module into `mkSandbox.nix` and `flake.nix`.

**Key Changes**:

1. **`flake.nix`**: Add `tmux` to `mkSandbox` parameters

```nix
# flake.nix - Updated API
mkSandbox = { 
  projectRoot, 
  services ? { postgres = true; }, 
  packages ? [ ], 
  env ? { }, 
  shellHook ? "", 
  postgresVersion ? null,
  tmux ? { enable = false; }  # NEW - zero-config ready
}:
```

2. **`lib/mkSandbox.nix`**: Import and wire tmux module with smart defaults

```nix
# At top of mkSandbox.nix, add parameter
, tmux ? { enable = false; }

# In let block - apply smart defaults
tmuxConfig = {
  sessionName = tmux.sessionName or null;  # null = auto-detect at runtime
  panes = tmux.panes or [{ command = "$SHELL"; }];  # Default: single shell
  layout = tmux.layout or "tiled";
  subpath = tmux.subpath or "";
};

tmuxModule = import ./tmux { 
  inherit lib pkgs;
  config = tmuxConfig;
};

tmuxPackages = lib.optionals (tmux.enable or false) [
  tmuxModule.spawnScript
  tmuxModule.pickScript
  tmuxModule.sessionsScript
  tmuxModule.killScript
  pkgs.tmux
  pkgs.fzf
];

# In devShell buildInputs
buildInputs = packages ++ tmuxPackages ++ [ ... ];
```

**Verification**:
- Fixture project with `tmux.enable = true` → All commands available
- Fixture without tmux config → No tmux commands (backward compatible)

---

### Phase 4: Documentation & Tests

**Goal**: Update README, add integration tests.

**Key Changes**:

1. **`README.md`**: Add Tmux Sessions section

```markdown
## Tmux Sessions (Optional)

Spawn isolated development sessions with auto-incrementing IDs.

### Zero-Config Usage

Just enable tmux - everything is auto-configured:

\`\`\`nix
devShells.default = dev-sandbox.lib.${system}.mkSandbox {
  projectRoot = ./.;
  services.postgres = true;
  
  tmux.enable = true;  # That's it!
};
\`\`\`

Then:
\`\`\`bash
nix develop
sandbox-spawn    # Creates "my-project #1" with a shell pane
sandbox-spawn    # Creates "my-project #2"
sandbox-pick     # Switch between sessions (fzf)
\`\`\`

### Custom Configuration (Optional)

\`\`\`nix
tmux = {
  enable = true;
  sessionName = "MyApp";           # Override auto-detected name
  panes = [
    { command = "nvim"; }
    { command = "sandbox-up && rails c"; delay = 2; }
    { command = "bin/dev"; delay = 5; }
  ];
  layout = "main-horizontal";      # tiled, main-vertical, even-horizontal, etc.
  subpath = "backend";             # For monorepos
};
\`\`\`

Commands:
- \`sandbox-spawn\` - Create new session (auto-increments ID)
- \`sandbox-spawn N\` - Create session with specific ID
- \`sandbox-pick\` - Attach to existing session (fzf picker)
- \`sandbox-sessions\` - List active sessions
- \`sandbox-kill [ID]\` - Kill session
```

2. **`tests/integration/tmux.bats`**: Integration tests

```bash
@test "sandbox-spawn creates session with auto-ID" {
  # Setup: ensure no sessions exist
  tmux kill-server 2>/dev/null || true
  
  # Run spawn in subshell (detached)
  run sandbox-spawn
  [ "$status" -eq 0 ]
  
  # Verify session exists
  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "Test #1" ]]
}

@test "sandbox-spawn respects explicit ID" {
  run sandbox-spawn 42
  [ "$status" -eq 0 ]
  
  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "Test #42" ]]
}

@test "sandbox-sessions lists only sandbox sessions" {
  # Create sandbox session and non-sandbox session
  tmux new-session -d -s "Other"
  sandbox-spawn
  
  run sandbox-sessions
  [[ "$output" =~ "Test #1" ]]
  [[ ! "$output" =~ "Other" ]]
}
```

**Verification**:
- `nix flake check` passes
- Manual test in fixture project

## 4. Risk Assessment & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Tmux not installed globally | Medium | High | Bundle `pkgs.tmux` in `buildInputs` when `tmux.enable = true` |
| Session name collisions across projects | Low | Medium | Include project hash in session name prefix (optional) |
| Pane commands fail silently | Medium | Medium | Add `set -e` in pane commands, log to `$SANDBOX_DIR/tmux.log` |
| User runs `sandbox-spawn` outside `nix develop` | High | Low | Commands only exist inside devShell; clear error if env vars missing |
| Complex delay logic race conditions | Medium | Medium | Use explicit `sleep` rather than tmux wait mechanisms |
| Breaking backward compatibility | Low | High | `tmux` config is entirely optional; no changes to existing behavior when omitted |

## 5. File Checklist

| File | Action | Priority |
|------|--------|----------|
| `lib/tmux/default.nix` | CREATE | P0 |
| `lib/mkSandbox.nix` | MODIFY (add tmux param, import module) | P0 |
| `flake.nix` | MODIFY (add tmux to mkSandbox signature) | P0 |
| `README.md` | MODIFY (add tmux section) | P1 |
| `tests/integration/tmux.bats` | CREATE | P1 |
| `tests/fixtures/rails-like/flake.nix` | MODIFY (add tmux example) | P2 |

## 6. User Journey

### Zero-Config Journey (Recommended)

```nix
# User adds to their flake.nix
tmux.enable = true;
```

```bash
# Enter dev environment
$ nix develop

# Spawn first session (auto-detects name from git repo)
$ sandbox-spawn
# → Creates "my-project #1" with single shell pane, attaches

# Later: spawn another parallel session
$ sandbox-spawn
# → Creates "my-project #2", attaches

# Switch between sessions
$ sandbox-pick
# → fzf shows "my-project #1", "my-project #2"

# Cleanup
$ sandbox-kill 1
# → Kills "my-project #1"
```

### Power User Journey

```nix
# User adds custom config to their flake.nix
tmux = {
  enable = true;
  sessionName = "MyApp";
  panes = [
    { command = "nvim"; }
    { command = "sandbox-up && rails c"; delay = 2; }
  ];
};
```

```bash
$ nix develop
$ sandbox-spawn
# → Creates "MyApp #1" with 2 panes (nvim + rails console), attaches
```

**Single memorable command**: `sandbox-spawn` — that's all users need to remember.
