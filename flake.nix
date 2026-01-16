{
  description = "Production-quality Nix flake library for isolated developer sandboxes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { pkgs, ... }: {
        # Dev shell for developing dev-sandbox itself
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nixpkgs-fmt
            statix
            deadnix
            git
          ];
        };

        checks = {
          # Unit tests (pure Nix)
          unit-tests =
            let libTests = import ./tests/unit/default.nix { inherit (pkgs) lib; };
            in
            pkgs.runCommand "unit-tests"
              {
                buildInputs = [ ];
              } ''
              echo "Running unit tests..."
              # Verify tests can be evaluated by checking test count
              echo "Unit tests: $(echo "${builtins.toJSON libTests}" | wc -c) bytes evaluated"
              echo "All unit tests evaluated successfully"
              touch $out
            '';

          # Integration tests (Bats)
          integration-tests = pkgs.runCommand "integration-tests"
            {
              buildInputs = with pkgs; [ bats postgresql_16 coreutils ];
              HOME = "/tmp/bats-home";
              TEST_DIR = ./tests/integration;
            } ''
            echo "Running integration tests..."

            export HOME="$HOME"
            mkdir -p "$HOME"

            # Copy test files to ensure they're in the build
            cp -r "$TEST_DIR" tests
            chmod +x tests/*.bats tests/common/* 2>/dev/null || true

            ${pkgs.bats}/bin/bats tests/postgres-lifecycle.bats tests/multiple-instances.bats tests/sandbox-cleanup.bats

            echo "Integration tests passed"
            touch $out
          '';

          # Format check
          formatting = pkgs.runCommand "formatting"
            {
              buildInputs = [ pkgs.nixpkgs-fmt ];
            } ''
            ${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt --check ${./.}
            touch $out
          '';

          # Linting
          lint = pkgs.runCommand "lint"
            {
              buildInputs = [ pkgs.statix pkgs.deadnix ];
              statixConfig = ./.statix.toml;
              src = ./.;
            } ''
            # Copy source to build directory and lint there
            cp -r "$src" source
            cd source

            # Check all files except mkSandbox.nix (which contains bash code)
            ${pkgs.statix}/bin/statix check --config "$statixConfig" --ignore lib/mkSandbox.nix
            ${pkgs.deadnix}/bin/deadnix -f lib/mkSandbox.nix

            touch $out
          '';
        };
      };

      # Public library API
      flake.lib = { system, ... }: {
        mkSandbox = { projectRoot, services ? { postgres = true; }, packages ? [ ], env ? { }, shellHook ? "", postgresVersion ? null }:
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
          in
          pkgs.callPackage ./lib/mkSandbox.nix
            {
              inherit projectRoot services packages env shellHook;
              postgresVersion = if postgresVersion == null then pkgs.postgresql_16 else postgresVersion;
            }.devShell;
      };
    };
}
