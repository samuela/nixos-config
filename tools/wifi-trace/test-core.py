"""Offline CO-RE resolution regression check; never load/attach BPF.

bpftool uses libbpf's CO-RE resolver. Successful min_core_btf exit alone is not
sufficient: missing fields can be intended optional relocations. Require a
matching target for EVERY declared relocation, and compare its exact field/bit
offset to the reference obtained from the full running kernel+module BTF.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

DECL = re.compile(r"^libbpf: prog '([^']+)': relo #(\d+): <([^>]+)> ")
MATCH = re.compile(r"^libbpf: prog '([^']+)': relo #(\d+): matching candidate #\d+ <([^>]+)> \[\d+\] (.+) \([^@]+@ offset ([\d.]+)\)$")


def resolutions(text):
    declared, matched = set(), {}
    for line in text.splitlines():
        m = DECL.match(line)
        if m:
            key = '|'.join(m.groups()[:2])
            assert key not in declared, ('duplicate relocation', key)
            declared.add(key)
        m = MATCH.match(line)
        if m:
            section, number, kind, field, offset = m.groups()
            key = section + '|' + number
            matched.setdefault(key, set()).add('|'.join((kind, field, offset)))
    assert declared, 'no CO-RE relocations checked'
    assert declared == matched.keys(), ('unresolved CO-RE relocations', sorted(declared - matched.keys()))
    assert all(len(v) == 1 for v in matched.values()), 'ambiguous relocation'
    return {k: next(iter(v)) for k, v in sorted(matched.items())}


def check(target, output):
    p = subprocess.run(['bpftool', '-d', 'gen', 'min_core_btf', str(target),
                        str(output), 'wifi-trace.bpf.o'], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    return resolutions(p.stderr)


def main():
    expected = json.loads(Path('core-reference.json').read_text())
    for path, digest in expected['sha256'].items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest, ('provenance mismatch', path)
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        actual = check('target-core.btf', directory / 'again.btf')
        assert actual == expected['relocations'], 'CO-RE offsets differ from full live BTF reference'
        # Regression: automatic vmlinux-only resolution missed this module type.
        # A well-formed BTF with that name removed must fail our coverage check.
        bad = directory / 'missing-mt76.btf'
        raw = Path('target-core.btf').read_bytes()
        assert raw.count(b'mt76_dev\0') == 1
        bad.write_bytes(raw.replace(b'mt76_dev\0', b'bad6_dev\0'))
        try:
            check(bad, directory / 'bad-min.btf')
        except AssertionError:
            pass
        else:
            raise AssertionError('missing module type incorrectly passed')
    # An empty log cannot accidentally certify an untested build.
    try:
        resolutions('')
    except AssertionError:
        pass
    else:
        raise AssertionError('empty log incorrectly passed')
    print(f"All {len(actual)} CO-RE relocations match full live BTF; missing-module negative check passed; no BPF loaded")


if __name__ == '__main__':
    main()
