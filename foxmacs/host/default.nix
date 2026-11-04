{
  lib,
  runCommand,
  writeShellApplication,
  socat,
}:
let
  host = writeShellApplication {
    name = "foxmacs-host";
    runtimeInputs = [ socat ];
    text = builtins.readFile ./foxmacs-host;
  };
  extension = lib.importJSON ../extension/manifest.json;
in
runCommand "foxmacs-host"
  {
    manifest = builtins.toJSON {
      name = "foxmacs";
      description = "Foxmacs";
      path = "${placeholder "out"}/bin/foxmacs-host";
      type = "stdio";
      allowed_extensions = [ extension.browser_specific_settings.gecko.id ];
    };
    passAsFile = [ "manifest" ];
  }
  ''
    mkdir -p $out/bin $out/lib/mozilla/native-messaging-hosts
    ln -s ${host}/bin/foxmacs-host $out/bin/foxmacs-host
    cp $manifestPath $out/lib/mozilla/native-messaging-hosts/foxmacs.json
  ''
