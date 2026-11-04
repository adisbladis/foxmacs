{
  description = "Control Firefox from Emacs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (
          system: f (import ./nix { pkgs = nixpkgs.legacyPackages.${system}; })
        );
    in
    {
      packages = forAllSystems (foxmacs: {
        inherit (foxmacs)
          foxmacs-extension
          tabs-to-windows
          foxmacs-host
          ;
      });

      lib = {
        emacsOverlay = import ./foxmacs/lisp/overlay.nix;
      };
    };
}
