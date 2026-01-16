# Shell script generators for sandbox management

{ pkgs }:

let
  # Generate sandbox-up script
  sandboxUpScript =
    pkgs.writeShellScript "sandbox-up" ''
      set -euo pipefail

      if [ -z "$SANDBOX_INSTANCE_ID" ]; then
        echo "Error: Not in a sandbox environment"
        exit 1
      fi

      # Use db_start for now (process-compose support can be added later)
      db_start
    '';

  # Generate sandbox-down script
  sandboxDownScript = sandboxDir:
    pkgs.writeShellScript "sandbox-down" ''
      set -euo pipefail

      if [ ! -f "${sandboxDir}/process-compose.yaml" ]; then
        echo "Error: No process-compose configuration found"
        exit 1
      fi

      echo "Stopping sandbox services..."
      cd "${sandboxDir}"
      ${pkgs.process-compose}/bin/process-compose down

      echo "Sandbox services stopped"
    '';

  # Generate sandbox-status script
  sandboxStatusScript = sandboxDir:
    pkgs.writeShellScript "sandbox-status" ''
      set -euo pipefail

      if [ ! -f "${sandboxDir}/process-compose.yaml" ]; then
        echo "No process-compose configuration found"
        exit 1
      fi

      echo "Sandbox status:"
      cd "${sandboxDir}"
      ${pkgs.process-compose}/bin/process-compose ps
    '';

  # Generate sandbox-list script
  sandboxListScript = { projectRoot }:
    pkgs.writeShellScript "sandbox-list" ''
      set -euo pipefail

      SANDBOXES_DIR="${projectRoot}/.sandboxes"

      if [ ! -d "$SANDBOXES_DIR" ]; then
        echo "No sandboxes found"
        exit 0
      fi

      echo "Available sandboxes:"
      echo ""

      for sandbox in "$SANDBOXES_DIR"/*; do
        if [ -d "$sandbox" ]; then
          INSTANCE_ID=$(basename "$sandbox")
          echo "  - $INSTANCE_ID"

          # Check for process-compose
          if [ -f "$sandbox/process-compose.yaml" ]; then
            cd "$sandbox"
            if ${pkgs.process-compose}/bin/process-compose ps > /dev/null 2>&1; then
              echo "    Status: Running (process-compose)"
            else
              echo "    Status: Stopped (process-compose)"
            fi
          else
            echo "    Status: Standalone mode"
          fi

          echo ""
        fi
      done
    '';

  # Generate sandbox-cleanup script
  sandboxCleanupScript = { projectRoot }:
    pkgs.writeShellScript "sandbox-cleanup" ''
      set -euo pipefail

      SANDBOXES_DIR="${projectRoot}/.sandboxes"

      if [ ! -d "$SANDBOXES_DIR" ]; then
        echo "No sandboxes found"
        exit 0
      fi

      echo "Cleaning up stale sandboxes..."
      echo ""

      REMOVED=0

      for sandbox in "$SANDBOXES_DIR"/*; do
        if [ -d "$sandbox" ]; then
          INSTANCE_ID=$(basename "$sandbox")

          # Check if process-compose is running for this sandbox
          if [ -f "$sandbox/process-compose.yaml" ]; then
            cd "$sandbox"
            if ${pkgs.process-compose}/bin/process-compose ps > /dev/null 2>&1; then
              echo "Skipping $INSTANCE_ID (services still running)"
              continue
            fi
          fi

          echo "Removing $INSTANCE_ID..."
          rm -rf "$sandbox"
          REMOVED=$((REMOVED + 1))
        fi
      done

      if [ $REMOVED -eq 0 ]; then
        echo "No stale sandboxes found"
      else
        echo "Removed $REMOVED sandbox(es)"
      fi
    '';

in
{
  inherit sandboxUpScript sandboxDownScript sandboxStatusScript sandboxListScript sandboxCleanupScript;
}
