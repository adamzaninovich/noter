{
  description = "Noter Flake";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        erlang_version = "28.4.1";
        elixir_version = "1.19.5";

        pkgs = import nixpkgs { inherit system; };
        beamPkgs = pkgs.beam.packages.erlang_28;

        erlang = assert beamPkgs.erlang.version == erlang_version; beamPkgs.erlang;
        elixir = assert beamPkgs.elixir_1_19.version == elixir_version; beamPkgs.elixir_1_19;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [ elixir ]
            ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.terminal-notifier;
        };
      });
}

