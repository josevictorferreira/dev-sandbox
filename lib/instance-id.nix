# Unique instance ID generation for sandbox isolation

{ lib }:

rec {
  # Generate a unique instance ID based on:
  # - Project path (deterministic)
  # - Shell timestamp (for parallel shells)
  # - Random element (collision resistance)
  #
  # The instance ID is used to create isolated sandbox environments
  # that can run concurrently without conflicting state.
  #
  # This function returns the shell command that will be executed
  # to generate the instance ID. It cannot be pure because it depends
  # on runtime state (current time, random).
  #
  # Returns: Shell script that prints the instance ID to stdout
  generateInstanceIdScript = pkgs: ''
    # Generate a unique instance ID
    # Combines: project hash (8 chars) + timestamp (8 chars) + random (4 chars)
    PROJECT_HASH=$(echo "${pkgs.path}" | ${pkgs.coreutils}/bin/md5sum | ${pkgs.coreutils}/bin/cut -c1-8)
    TIMESTAMP=$(${pkgs.coreutils}/bin/date +%s | ${pkgs.coreutils}/bin/tail -c 8)
    RANDOM_PART=$(${pkgs.coreutils}/bin/od -An -N2 -tx2 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' ')

    echo "''${PROJECT_HASH}''${TIMESTAMP}''${RANDOM_PART}"
  '';

  # Generate a unique instance ID as a pure Nix expression
  # This is used for testing purposes where we need deterministic IDs
  # In production, use generateInstanceIdScript instead
  #
  # This is not truly unique - it's only for testing!
  generateTestInstanceId = { projectRoot, counter ? 0 }:
    let
      hash = builtins.hashString "sha256" (toString projectRoot);
      # Use first 8 chars of hash + counter
      id = builtins.substring 0 8 hash + builtins.toString counter;
    in
    id;

  # Validate an instance ID format
  # Expected format: 20 hex characters (8+8+4)
  validateInstanceId = id:
    let
      isValidLength = builtins.stringLength id == 20;
      # Check if all characters are hex digits
      isHex = lib.all (c: lib.any (c'': c == c'') [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c" "d" "e" "f" ]) (lib.stringToChars id);
    in
    isValidLength && isHex;

  # Derive the sandbox state directory path for an instance
  # Returns path: $PROJECT_ROOT/.sandboxes/<instance-id>
  deriveSandboxDir = projectRoot: instanceId:
    "${projectRoot}/.sandboxes/${instanceId}";

  # Derive service-specific paths within a sandbox
  # Common paths: data, sockets, logs, config
  deriveServicePaths = sandboxDir: serviceName: {
    data = "${sandboxDir}/${serviceName}/data";
    socket = "${sandboxDir}/${serviceName}/socket";
    log = "${sandboxDir}/${serviceName}/log";
    config = "${sandboxDir}/${serviceName}/config";
  };
}
