{
  description = "CMU Compilers development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            zig
            zsh
            python313
            pkg-config
            lld
            rocmPackages.rocm-runtime
          ];

          HSA_RUNTIME_PATH = "${pkgs.rocmPackages.rocm-runtime}";

          shellHook = ''
            if [ -z "$ZSH_VERSION" ] && [ -z "$NIX_DEVELOP_ZSH" ]; then
              export NIX_DEVELOP_ZSH=1
              export SHELL=${pkgs.zsh}/bin/zsh
              exec ${pkgs.zsh}/bin/zsh
            fi
          '';
        };
      });
    };
}
