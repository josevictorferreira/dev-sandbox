# Deterministic port allocation for sandbox instances

{ lib }:

rec {
  # Modulo operation since Nix doesn't have a built-in modulo operator
  mod = a: b: a - (b * (a / b));

  # Convert a string to a list of single-character strings
  stringToChars = s:
    let
      len = builtins.stringLength s;
      loop = i:
        if i >= len
        then [ ]
        else [ (builtins.substring i 1 s) ] ++ (loop (i + 1));
    in
    loop 0;

  # Hash a path to a deterministic numeric value
  # Returns a number in range [0, 2^32-1]
  hashPath = path:
    let
      # Convert path to string and hash with builtins.hashString
      # Using "sha256" for wide distribution
      hashed = builtins.hashString "sha256" (toString path);
      # Convert hex string to integer (first 8 chars = 32 bits)
      hexChars = stringToChars hashed;
      hexToInt = c:
        let
          code = lib.strings.charToInt c;
        in
        if code == null
        then 0
        else code;
      accumulate = chars:
        builtins.foldl' (acc: c: acc * 16 + hexToInt c) 0 chars;
    in
    accumulate (lib.sublist 0 8 hexChars);

  # Derive a base port for a project
  # Port is deterministic and collision-resistant based on projectRoot
  # Returns port in range [10000, 10500)
  deriveBasePort = projectRoot:
    let
      hashValue = hashPath projectRoot;
      base = 10000;
      range = 500;
      offset = mod hashValue range;
    in
    base + offset;

  # Derive a port for a specific instance
  # Instance ID is used to offset from base port, allowing parallel shells
  # Returns port in range [10000, 10500)
  deriveInstancePort = { projectRoot, instanceId }:
    let
      basePort = deriveBasePort projectRoot;
      # Use instanceId to add offset within the range
      # This allows up to range/2 = 250 concurrent instances safely
      # (leaving room for multiple services per instance)
      range = 500;
      offset = mod (instanceId * 2) range;
    in
    basePort + offset;

  # Derive a port for a specific service within an instance
  # Allows multiple services per instance (e.g., postgres, redis)
  deriveServicePort = { projectRoot, instanceId, serviceIndex ? 0 }:
    let
      basePort = deriveBasePort projectRoot;
      range = 500;
      # instanceOffset uses even numbers
      instanceOffset = mod (instanceId * 2) range;
    in
    basePort + instanceOffset + serviceIndex;

  # Validate that a port is within the allowed range
  isValidPort = port:
    lib.assertMsg (port >= 10000 && port < 10500)
      "Port ${toString port} must be in range [10000, 10500)"
      (port >= 10000 && port < 10500);
}
