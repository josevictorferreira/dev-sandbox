{
  description = "Rails-like consumer fixture for dev-sandbox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    dev-sandbox.url = "path:../../";
    dev-sandbox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, dev-sandbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = dev-sandbox.lib.${system}.mkSandbox {
        projectRoot = ./.;
        services = {
          postgres = true;
        };
        packages = with pkgs; [
          ruby_3_2
          bundler
          nodejs
          yarn
        ];
        env = {
          RAILS_ENV = "development";
          RACK_ENV = "development";
          DATABASE_URL = "postgresql://postgres:postgres@localhost:$PGPORT/rails_development";
        };
        shellHook = ''
          echo "Rails-like development environment"
          echo "PostgreSQL: $PGHOST:$PGPORT"
          echo ""
          echo "Use 'db_start' to start PostgreSQL"
          echo "Use 'db_stop' to stop PostgreSQL"
        '';
        postgresVersion = pkgs.postgresql_15;
      };
    };
}
