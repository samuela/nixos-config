# Standalone diagnostic tool; not installed/enabled by the host configuration.
# Build: nix-build tools/wifi-trace --no-out-link --option builders ''
{
  pkgs ? import (import ../../nix/pinned-nixpkgs-path.nix) { },
}:
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
pkgs.stdenv.mkDerivation {
  pname = "wifi-trace";
  version = "0.5";
  src = ./.;
  nativeBuildInputs = [
    pkgs.llvmPackages.clang-unwrapped
    pkgs.pkg-config
  ];
  buildInputs = [ pkgs.libbpf ];
  nativeCheckInputs = [ pkgs.python3 pkgs.bpftools ];
  dontStrip = true; # Keep .BTF/.BTF.ext in the BPF object for CO-RE relocation.
  buildPhase = ''
    runHook preBuild
    clang -target bpf -D__BPF__ -D__TARGET_ARCH_x86 -O2 -g \
      -I${pkgs.linuxHeaders}/include $(pkg-config --cflags libbpf) \
      -Wall -Werror -c wifi-trace.bpf.c -o wifi-trace.bpf.o
    $CC -std=c11 -O2 -g -Wall -Wextra -Werror \
      -DBPF_OBJECT_PATH=\"$out/lib/wifi-trace.bpf.o\" \
      -DCORE_BTF_PATH=\"$out/lib/target-core.btf\" \
      wifi-trace.c $(pkg-config --cflags --libs libbpf) -o wifi-trace
    $CC -std=c11 -O1 -g -Wall -Wextra -Werror \
      -fsanitize=address,undefined -fno-omit-frame-pointer \
      test-packet.c -o test-packet
    $CC -std=c11 -O1 -g -Wall -Wextra -Werror \
      -fsanitize=address,undefined -fno-omit-frame-pointer \
      test-loader.c $(pkg-config --cflags --libs libbpf) -o test-loader
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./test-packet
    ./test-loader
    python3 test-core.py
    python3 - <<'PY'
    import json
    from pathlib import Path
    rows = [json.loads(line) for line in Path("serializer.jsonl").read_text().splitlines()]
    assert len(rows) == 2
    assert rows[0]["event"] == "tx_descriptor" and rows[0]["message"] == 2
    assert rows[0]["txd"] == [0, 0, 0, 2, 0, 0x1234, 0, 0]
    assert rows[0]["key_present"] == 1 and rows[0]["eapol_len"] == 130
    assert rows[1]["event"] == "test_footer"
    print("JSON schema and TX packet-number redaction passed")
    PY
    ./wifi-trace --help
    check_exit() {
      expected=$1
      shift
      status=0
      ./wifi-trace "$@" > cli.log 2>&1 || status=$?
      test "$status" -eq "$expected"
      if test "$expected" -eq 1; then
        grep -q '^Root is required to attach BPF probes; nothing was attached\.$' cli.log
      fi
    }
    check_exit 2 --seconds -1
    check_exit 2 --seconds 4294967296
    check_exit 2 --seconds garbage
    check_exit 2 --stream
    grep -q '^--stream requires a pipe' cli.log
    # Valid timer arguments reach the root guard, not the argument-error path.
    # Fail closed under a root builder: never let these tests reach BPF loading.
    test "$(id -u)" -ne 0
    check_exit 1
    check_exit 1 --seconds 0
    check_exit 1 --seconds 1
    check_exit 1 --seconds 604800
    # A real anonymous pipe passes the stream sink guard but still refuses
    # nonroot attachment. No kernel probe is loaded by this test.
    python3 - <<'PY'
    import subprocess
    p = subprocess.run(['./wifi-trace', '--stream'], capture_output=True)
    assert p.returncode == 1 and b'Root is required' in p.stderr
    PY
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 wifi-trace "$out/bin/wifi-trace"
    install -Dm644 wifi-trace.bpf.o "$out/lib/wifi-trace.bpf.o"
    install -Dm644 target-core.btf "$out/lib/target-core.btf"
    runHook postInstall
  '';
}
