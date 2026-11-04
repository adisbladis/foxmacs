{
  lib,
  buildNpmPackage,
  importNpmLock,
  zip,
}:
let
  manifest = lib.importJSON ./manifest.json;
in
buildNpmPackage {
  pname = "foxmacs-extension";
  inherit (manifest) version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./manifest.json
      ./background.js
      ./page.js
      ./package.json
      ./package-lock.json
    ];
  };
  npmDeps = importNpmLock { npmRoot = ./.; };
  inherit (importNpmLock) npmConfigHook;
  dontNpmBuild = true;
  nativeBuildInputs = [ zip ];
  installPhase = ''
    runHook preInstall
    dst="$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
    mkdir -p "$dst"
    # npm sets mtimes to the build time
    touch -d @1 node_modules/@mozilla/readability/Readability.js
    zip -X "$dst/${manifest.browser_specific_settings.gecko.id}.xpi" \
      manifest.json background.js page.js node_modules/@mozilla/readability/Readability.js
    runHook postInstall
  '';
}
