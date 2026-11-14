{
  description = "Optional aarch64-linux compiler experiment; not a TensorFold package";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { inherit system; };
      zig = pkgs.stdenvNoCC.mkDerivation rec {
        pname = "tensorfold-zig-bin";
        version = "0.17.1";

        # Same archive, mirror order and byte hash as scripts/config.sh + zig/Dockerfile.
        src = pkgs.fetchurl {
          urls = [
            "https://zig.linus.dev/zig/zig-aarch64-linux-${version}.tar.xz"
            "https://ziglang.org/download/${version}/zig-aarch64-linux-${version}.tar.xz"
          ];
          sha256 = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795";
        };

        dontConfigure = true;
        dontBuild = true;
        # Retain the pinned upstream executable unchanged.
        dontStrip = true;
        dontPatchELF = true;

        installPhase = ''
          runHook preInstall
          install -Dm755 zig "$out/bin/zig"
          mkdir -p "$out/lib/zig" "$out/share/doc/zig"
          cp -R lib/. "$out/lib/zig/"
          cp LICENSE README.md "$out/share/doc/zig/"
          runHook postInstall
        '';

        # Run only on Linux: also prove the relocated compiler finds its bundled stdlib.
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          test "$("$out/bin/zig" version)" = "${version}"
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
          printf '%s\n' 'test { try @import("std").testing.expect(true); }' > "$TMPDIR/smoke.zig"
          "$out/bin/zig" test "$TMPDIR/smoke.zig" --cache-dir "$TMPDIR/zig-local-cache"
          runHook postInstallCheck
        '';

        meta = {
          description = "Pinned upstream Zig compiler archive for the optional TensorFold experiment";
          homepage = "https://ziglang.org/";
          license = pkgs.lib.licenses.mit;
          platforms = [ system ];
          mainProgram = "zig";
          sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
        };
      };
    in {
      packages.${system} = {
        inherit zig;
        zig-nixpkgs = pkgs.zig_0_17;
        default = zig;
      };
      checks.${system} = {
        inherit zig;
        zig-libc = pkgs.runCommand "tensorfold-zig-libc-smoke" {
          nativeBuildInputs = [ pkgs.zig_0_17 pkgs.stdenv.cc ];
        } ''
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
          cat > probe.c <<'EOF'
          #include <stdlib.h>
          int libc_probe(int n) { return abs(n); }
          EOF
          cat > smoke.zig <<'EOF'
          const std = @import("std");
          extern "c" fn libc_probe(c_int) c_int;
          test "libc headers and linkage" {
              try std.testing.expectEqual(@as(c_int, 7), libc_probe(-7));
          }
          EOF
          zig test smoke.zig probe.c -lc --cache-dir "$TMPDIR/zig-local-cache"
          mkdir -p "$out"
          zig version > "$out/compiler-version"
        '';
      };
    };
}
