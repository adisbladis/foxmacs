{
  pkgs ? import <nixpkgs> { },
}:
{
  foxmacs-extension = pkgs.callPackage ../foxmacs/extension { };
  foxmacs-host = pkgs.callPackage ../foxmacs/host { };
  tabs-to-windows = pkgs.callPackage ../tabs-to-windows { };
  emacsOverlay = import ../foxmacs/lisp/overlay.nix;
}
