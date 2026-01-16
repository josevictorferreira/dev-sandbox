# Unit tests for dev-sandbox

{ lib }:

let
  ports = import ../../lib/ports.nix { inherit lib; };
  instanceId = import ../../lib/instance-id.nix { inherit lib; };

in
lib.runTests {
  # Port allocation tests
  test-port-in-range = {
    expr = builtins.all (p: p >= 10000 && p < 10500) [
      (ports.deriveBasePort ./.)
      (ports.deriveBasePort /tmp)
      (ports.deriveBasePort /home)
    ];
    expected = true;
  };

  test-port-determinism = {
    expr = ports.deriveBasePort ./.;
    expected = ports.deriveBasePort ./.;
  };

  test-port-different-paths-different-ports = {
    expr = ports.deriveBasePort ./tests == ports.deriveBasePort ./lib;
    expected = false;
  };

  test-instance-port-unique = {
    expr = ports.deriveInstancePort { projectRoot = ./.; instanceId = 0; }
      == ports.deriveInstancePort { projectRoot = ./.; instanceId = 1; };
    expected = false;
  };

  test-modulo = {
    expr = ports.mod 10 3;
    expected = 1;
  };

  # Instance ID tests
  test-instance-id-length = {
    expr = builtins.stringLength (instanceId.generateTestInstanceId { projectRoot = ./.; });
    expected = 8;
  };

  test-instance-id-different-counters = {
    expr = instanceId.generateTestInstanceId { projectRoot = ./.; counter = 0; }
      == instanceId.generateTestInstanceId { projectRoot = ./.; counter = 1; };
    expected = false;
  };

  test-sandbox-dir-path = {
    expr = instanceId.deriveSandboxDir ./test-project "abc123";
    expected = toString ./test-project + "/.sandboxes/abc123";
  };

  test-service-paths = {
    expr = instanceId.deriveServicePaths "/sandbox" "postgres";
    expected = {
      data = "/sandbox/postgres/data";
      socket = "/sandbox/postgres/socket";
      log = "/sandbox/postgres/log";
      config = "/sandbox/postgres/config";
    };
  };

  test-validate-instance-id-valid = {
    expr = instanceId.validateInstanceId "01234567890123456789";
    expected = true;
  };

  test-validate-instance-id-invalid-length = {
    expr = instanceId.validateInstanceId "abc";
    expected = false;
  };

  test-validate-instance-id-invalid-chars = {
    expr = instanceId.validateInstanceId "0123456789012345678x";
    expected = false;
  };
}
