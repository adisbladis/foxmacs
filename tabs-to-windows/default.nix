{
  lib,
  runCommand,
  zip,
}:
let
  manifest = lib.importJSON ./manifest.json;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./manifest.json
      ./background.js
    ];
  };
in
runCommand "tabs-to-windows-${manifest.version}" { nativeBuildInputs = [ zip ]; } ''
  dst="$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
  mkdir -p "$dst"
  cd ${src}
  zip -X "$dst/${manifest.browser_specific_settings.gecko.id}.xpi" manifest.json background.js
''
