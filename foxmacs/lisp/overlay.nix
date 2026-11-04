final: _prev: {
  foxmacs = final.callPackage (
    { lib, trivialBuild }:
    trivialBuild {
      pname = "foxmacs";
      version = "0.1";
      src = lib.fileset.toSource {
        root = ./.;
        fileset = ./foxmacs.el;
      };
    }
  ) { };

  foxmacs-helm = final.callPackage (
    {
      lib,
      trivialBuild,
      foxmacs,
      helm,
    }:
    trivialBuild {
      pname = "foxmacs-helm";
      version = "0.1";
      src = lib.fileset.toSource {
        root = ./.;
        fileset = ./foxmacs-helm.el;
      };
      packageRequires = [
        foxmacs
        helm
      ];
    }
  ) { };
}
