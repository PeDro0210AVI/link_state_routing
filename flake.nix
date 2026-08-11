{
  description = "A Nix-flake-based Zig development environment and for python env";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1"; # unstable Nixpkgs

  outputs =
    { self, nixpkgs, ... }@inputs:

    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs supportedSystems (
          system:
          let

            pkgs = import inputs.nixpkgs {
              inherit system;
            };

            pythonPackages =
              ps: with ps; [
                python
              ];

            pythonEnv = pkgs.python3.withPackages pythonPackages;
          in
          f {
            inherit
              system
              pythonEnv
              pkgs
              ;
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        {
          pkgs,
          system,
          pythonEnv,
        }:
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              # All zig releated
              zig
              zls
              lldb

              self.formatter.${system}

              pythonEnv
              pkgs.pyright
            ];
          };
        }
      );

      formatter = forEachSupportedSystem ({ pkgs, ... }: pkgs.nixfmt);
    };
}
