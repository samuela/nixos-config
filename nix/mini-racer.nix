{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  python3Packages,
}:

# Upstream's sdist cannot build V8 through the ordinary Python build process.
# Use the official PyPI wheel (ctypes, no CPython ABI), not legacy py-mini-racer.
# This deliberately trusts upstream's prebuilt V8 and supports x86_64 Linux only.
python3Packages.buildPythonPackage rec {
  pname = "mini-racer";
  version = "0.14.1";
  format = "wheel";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/c2/3c/c5bd479784826bbbc69f713aae2bcfd5ef353ba4e5e0e661666938474535/mini_racer-${version}-py3-none-manylinux_2_27_x86_64.whl";
    hash = "sha256-zfOgiOE2PxamlSiPiCq/drNwW44d8hQYIIuH7QEAN6Q=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  pythonImportsCheck = [ "py_mini_racer" ];

  meta = {
    description = "Modern embedded V8 for Python (upstream binary wheel)";
    homepage = "https://github.com/bpcreech/PyMiniRacer";
    license = lib.licenses.isc;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
