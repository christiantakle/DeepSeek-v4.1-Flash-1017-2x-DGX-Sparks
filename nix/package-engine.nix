{ pkgs, engine }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "tensorfold-engine-package-sm121";
  inherit (engine) version;

  outputs = [ "out" "debug" ];
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.binutils ];

  # Use the normal strip hook for both executable directories. The engine's
  # existing interpreter and runpaths already passed its packaging checks.
  stripDebugList = [ "bin" "native/bin" ];
  dontPatchELF = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out" "$debug"
    cp -a ${engine}/. "$out/"
    chmod -R u+w "$out"
    # This is the original executable, not a build-ID-indexed split debug file.
    # Keep the link outside stripDebugList so fixup never traverses its target.
    ln -s ${engine}/native/bin/tensorfold-native "$debug/tensorfold-native-unstripped"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    for binary in native/bin/tensorfold-native bin/tf-dsv41-lanes bin/tf-dsv41-rank-cache; do
      test -x "$out/$binary"
    done
    for tool in make_token_map.py make_rope.py make_bias_vl.py; do
      test -s "$out/tools/inputs/$tool"
    done
    test -s "$out/share/doc/tensorfold/LICENSE"
    test -s "$out/share/doc/tensorfold/LICENSE-inputs-branch"
    test -L "$debug/tensorfold-native-unstripped"
    test -x "$debug/tensorfold-native-unstripped"
    if readelf -SW "$out/native/bin/tensorfold-native" | grep -q '\.debug_'; then
      echo "packaged native executable still contains DWARF sections" >&2
      exit 1
    fi
    "$out/native/bin/tensorfold-native" capabilities --json > "$TMPDIR/capabilities.json"
    test -s "$TMPDIR/capabilities.json"
    runHook postInstallCheck
  '';

  meta = engine.meta // {
    description = "TensorFold executable package with optional original unstripped diagnostic executable";
    outputsToInstall = [ "out" ];
  };
}
