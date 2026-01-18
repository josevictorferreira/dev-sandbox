#!/usr/bin/env bats
# tests/integration/tmux.bats - Integration tests for tmux session spawner
# Phase 1: Core tmux module testing

# Load common test utilities
load 'common/test_helper'

# Test fixture configuration
TEST_SESSION_BASE="dev-sandbox-test"

setup() {
  # Create temporary test directory
  export TEST_TMPDIR=$(mktemp -d)
  export TEST_PROJECT_DIR="$TEST_TMPDIR/test-project"
  mkdir -p "$TEST_PROJECT_DIR"

  # Initialize as git repo for session name detection
  cd "$TEST_PROJECT_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"

  # Clean any existing test sessions
  tmux list-sessions -F '#{session_name}' 2>/dev/null | \
    grep -E "^${TEST_SESSION_BASE} #" | \
    xargs -I {} tmux kill-session -t "{}" 2>/dev/null || true
}

teardown() {
  # Clean up test sessions
  tmux list-sessions -F '#{session_name}' 2>/dev/null | \
    grep -E "^${TEST_SESSION_BASE} #" | \
    xargs -I {} tmux kill-session -t "{}" 2>/dev/null || true

  # Clean up temp directory
  if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# Helper: Build spawn script from tmux module
build_spawn_script() {
  local session_name="${1:-}"
  local config_expr

  if [ -n "$session_name" ]; then
    config_expr="{ sessionName = \"$session_name\"; panes = [{ command = \"\$SHELL\"; }]; }"
  else
    config_expr="{ panes = [{ command = \"\$SHELL\"; }]; }"
  fi

  nix-build --no-out-link -E "
    let
      pkgs = import <nixpkgs> {};
      lib = pkgs.lib;
      config = $config_expr;
      tmuxModule = import ./lib/tmux/default.nix { inherit lib pkgs config; };
    in tmuxModule.spawnScript
  " 2>/dev/null
}

@test "sandbox-spawn creates session with auto-ID #1 when no sessions exist" {
  # Build spawn script with explicit session name for testing
  local spawn_script=$(build_spawn_script "$TEST_SESSION_BASE")
  skip_if_no_script "$spawn_script"

  # Run spawn in background (don't attach)
  cd "$TEST_PROJECT_DIR"
  TMUX="" timeout 5 "$spawn_script/bin/sandbox-spawn" &
  local pid=$!
  sleep 2
  kill $pid 2>/dev/null || true

  # Verify session was created with #1
  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "$TEST_SESSION_BASE #1" ]]
}

@test "sandbox-spawn respects explicit ID argument" {
  local spawn_script=$(build_spawn_script "$TEST_SESSION_BASE")
  skip_if_no_script "$spawn_script"

  cd "$TEST_PROJECT_DIR"
  TMUX="" timeout 5 "$spawn_script/bin/sandbox-spawn" 42 &
  local pid=$!
  sleep 2
  kill $pid 2>/dev/null || true

  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "$TEST_SESSION_BASE #42" ]]
}

@test "sandbox-spawn auto-increments session ID" {
  local spawn_script=$(build_spawn_script "$TEST_SESSION_BASE")
  skip_if_no_script "$spawn_script"

  cd "$TEST_PROJECT_DIR"

  # Create first session
  TMUX="" timeout 5 "$spawn_script/bin/sandbox-spawn" &
  sleep 2
  kill $! 2>/dev/null || true

  # Create second session
  TMUX="" timeout 5 "$spawn_script/bin/sandbox-spawn" &
  sleep 2
  kill $! 2>/dev/null || true

  # Both sessions should exist with sequential IDs
  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "$TEST_SESSION_BASE #1" ]]
  [[ "$output" =~ "$TEST_SESSION_BASE #2" ]]
}

@test "sandbox-spawn auto-detects session name from git repo" {
  # Build without explicit session name (auto-detect)
  local spawn_script=$(nix-build --no-out-link -E "
    let
      pkgs = import <nixpkgs> {};
      lib = pkgs.lib;
      config = { panes = [{ command = \"\$SHELL\"; }]; };
      tmuxModule = import ./lib/tmux/default.nix { inherit lib pkgs config; };
    in tmuxModule.spawnScript
  " 2>/dev/null)
  skip_if_no_script "$spawn_script"

  cd "$TEST_PROJECT_DIR"

  # Repo name is "test-project" from directory
  TMUX="" timeout 5 "$spawn_script/bin/sandbox-spawn" &
  sleep 2
  kill $! 2>/dev/null || true

  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "test-project #1" ]]
}

# Helper function to skip test if script build failed
skip_if_no_script() {
  if [ -z "$1" ] || [ ! -x "$1/bin/sandbox-spawn" ]; then
    skip "Failed to build spawn script"
  fi
}

# =====================================================
# Phase 2 Tests: Session Management Commands
# =====================================================

# Helper: Build all tmux scripts from module
build_tmux_scripts() {
  local session_name="${1:-}"
  local config_expr

  if [ -n "$session_name" ]; then
    config_expr="{ sessionName = \"$session_name\"; panes = [{ command = \"\$SHELL\"; }]; }"
  else
    config_expr="{ panes = [{ command = \"\$SHELL\"; }]; }"
  fi

  nix-build --no-out-link -E "
    let
      pkgs = import <nixpkgs> {};
      lib = pkgs.lib;
      config = $config_expr;
      tmuxModule = import ./lib/tmux/default.nix { inherit lib pkgs config; };
    in pkgs.symlinkJoin {
      name = \"tmux-scripts\";
      paths = [
        tmuxModule.spawnScript
        tmuxModule.pickScript
        tmuxModule.sessionsScript
        tmuxModule.killScript
      ];
    }
  " 2>/dev/null
}

@test "sandbox-sessions lists only sandbox sessions (not unrelated)" {
  local scripts=$(build_tmux_scripts "$TEST_SESSION_BASE")
  [ -n "$scripts" ] || skip "Failed to build tmux scripts"

  cd "$TEST_PROJECT_DIR"

  # Create unrelated tmux session
  tmux new-session -d -s "unrelated-session"

  # Create sandbox session
  TMUX="" timeout 5 "$scripts/bin/sandbox-spawn" &
  sleep 2
  kill $! 2>/dev/null || true

  # Verify sandbox-sessions lists only sandbox session
  run "$scripts/bin/sandbox-sessions"
  [[ "$output" =~ "$TEST_SESSION_BASE #1" ]]
  [[ ! "$output" =~ "unrelated-session" ]]

  # Cleanup unrelated session
  tmux kill-session -t "unrelated-session" 2>/dev/null || true
}

@test "sandbox-kill with explicit ID kills specific session" {
  local scripts=$(build_tmux_scripts "$TEST_SESSION_BASE")
  [ -n "$scripts" ] || skip "Failed to build tmux scripts"

  cd "$TEST_PROJECT_DIR"

  # Create two sandbox sessions
  TMUX="" timeout 5 "$scripts/bin/sandbox-spawn" &
  sleep 2
  kill $! 2>/dev/null || true

  TMUX="" timeout 5 "$scripts/bin/sandbox-spawn" &
  sleep 2
  kill $! 2>/dev/null || true

  # Verify both exist
  run tmux list-sessions -F '#{session_name}'
  [[ "$output" =~ "$TEST_SESSION_BASE #1" ]]
  [[ "$output" =~ "$TEST_SESSION_BASE #2" ]]

  # Kill session #1
  run "$scripts/bin/sandbox-kill" 1
  [ "$status" -eq 0 ]

  # Verify #1 gone, #2 still exists
  run tmux list-sessions -F '#{session_name}'
  [[ ! "$output" =~ "$TEST_SESSION_BASE #1" ]]
  [[ "$output" =~ "$TEST_SESSION_BASE #2" ]]
}

@test "sandbox-pick exits gracefully when no sessions exist" {
  local scripts=$(build_tmux_scripts "$TEST_SESSION_BASE")
  [ -n "$scripts" ] || skip "Failed to build tmux scripts"

  cd "$TEST_PROJECT_DIR"

  # Ensure no sandbox sessions exist
  tmux list-sessions -F '#{session_name}' 2>/dev/null | \
    grep -E "^${TEST_SESSION_BASE} #" | \
    xargs -I {} tmux kill-session -t "{}" 2>/dev/null || true

  # Run pick - should exit gracefully with message
  run "$scripts/bin/sandbox-pick"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No sandbox sessions found" ]]
}
