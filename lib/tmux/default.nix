# lib/tmux/default.nix - Tmux session spawning module
# Phase 1: Core tmux session management for dev-sandbox

{ lib, pkgs, config }:

let
  # Config with smart defaults applied
  sessionNameConfigured = config.sessionName or null; # null = auto-detect at runtime
  panes = config.panes or [{ command = "$SHELL"; }]; # Default: single shell pane
  layout = config.layout or "tiled";
  subpath = config.subpath or "";

  # Session name derivation logic (runtime bash)
  sessionNameDerivation = ''
    # Auto-detect session name from git repo or directory
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
      SESSION_BASE=$(basename "$(git rev-parse --show-toplevel)")
    else
      SESSION_BASE=$(basename "$PWD")
    fi
  '';

  # If user configured a name, use it directly
  sessionNameScript =
    if sessionNameConfigured != null
    then ''SESSION_BASE="${sessionNameConfigured}"''
    else sessionNameDerivation;

  # Generate pane creation commands
  # First pane is created with session, rest are splits
  mkPaneCommand = i: pane:
    let
      delay = pane.delay or 0;
      cmd = pane.command or "$SHELL";
      delayCmd = if delay > 0 then "sleep ${toString delay} && " else "";
      paneTarget = "$SESSION_NAME:0.${toString i}";
      # Build the command to send - use double quotes and escape properly
      paneCmd = ''${delayCmd}${cmd}'';
    in
    if i == 0 then
    # First pane: send command to existing window
      ''
        ${pkgs.tmux}/bin/tmux send-keys -t "${paneTarget}" "cd \"$PROJECT_DIR/${subpath}\" && nix develop --command \$SHELL -c '${paneCmd}'" Enter
      ''
    else
    # Additional panes: split first, then send command
      ''
        ${pkgs.tmux}/bin/tmux split-window -t "$SESSION_NAME"
        ${pkgs.tmux}/bin/tmux send-keys -t "${paneTarget}" "cd \"$PROJECT_DIR/${subpath}\" && nix develop --command \$SHELL -c '${paneCmd}'" Enter
      '';

  paneCommands = lib.imap0 mkPaneCommand panes;

in
{
  # Expose sessionNameScript for reuse in all scripts
  inherit sessionNameScript;

  # sandbox-spawn: Create new tmux session with configurable panes
  spawnScript = pkgs.writeShellScriptBin "sandbox-spawn" ''
    set -euo pipefail

    PROJECT_DIR="$PWD"

    # Determine session name (configured or auto-detected)
    ${sessionNameScript}

    # Get explicit ID or auto-detect next available
    if [ -n "''${1:-}" ]; then
      SESSION_ID="$1"
    else
      # Extract existing IDs from session names matching pattern
      MAX_ID=0
      while IFS= read -r name; do
        # Match pattern: "SessionName #N" - extract N
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
    ${pkgs.tmux}/bin/tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR/${subpath}"

    # Create panes and run commands
    ${lib.concatStringsSep "\n" paneCommands}

    # Apply layout
    ${pkgs.tmux}/bin/tmux select-layout -t "$SESSION_NAME" ${layout}

    # Attach or switch based on whether we're already in tmux
    if [ -n "''${TMUX:-}" ]; then
      ${pkgs.tmux}/bin/tmux switch-client -t "$SESSION_NAME"
    else
      ${pkgs.tmux}/bin/tmux attach-session -t "$SESSION_NAME"
    fi
  '';

  # sandbox-pick: fzf picker for existing sandbox sessions
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

  # sandbox-sessions: List active sandbox sessions
  sessionsScript = pkgs.writeShellScriptBin "sandbox-sessions" ''
    set -euo pipefail

    ${sessionNameScript}

    PATTERN="^$SESSION_BASE #"

    echo "Active Sandbox Sessions ($SESSION_BASE):"
    echo ""

    ${pkgs.tmux}/bin/tmux list-sessions -F '  #{session_name} (#{session_windows} windows, created #{session_created_string})' 2>/dev/null \
      | grep -E "$PATTERN" || echo "  (none)"
  '';

  # sandbox-kill: Kill sandbox session by ID or via fzf
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
}
