"""Offline packaged-code checks; not a full TLS audit or a device/cloud test."""

import asyncio
import base64
from datetime import datetime, timedelta, timezone
import importlib.metadata
import inspect
import os
from pathlib import Path
import socket
import sys
from types import SimpleNamespace
from threading import Lock
import unittest
from unittest.mock import Mock, patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from cryptography.x509.verification import Store
from py_mini_racer import MiniRacer

# Fail closed if any check accidentally attempts a network connection.
def no_network(*args, **kwargs):
    raise AssertionError("network access is forbidden in this test")


socket.create_connection = no_network
socket.socket.connect = no_network
socket.socket.connect_ex = no_network

import custom_components.dreame_vacuum as component
from custom_components.dreame_vacuum import config_flow
from custom_components.dreame_vacuum.dreame import protocol
from custom_components.dreame_vacuum.dreame.resources import MAP_OPTIMIZER_JS

Cloud = protocol.DreameVacuumDreameHomeCloudProtocol
TLS = Cloud.DreameTLSSocket


def certificate_authority(name, *, private=False):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    now = datetime.now(timezone.utc)
    builder = (
        x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=2))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    )
    if not private:
        builder = builder.add_extension(
            x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True
        )
    return key, builder.sign(key, hashes.SHA256())


def leaf_certificate(authority, *, expired=False, private=False):
    ca_key, ca = authority
    key = ec.generate_private_key(ec.SECP256R1())
    now = datetime.now(timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "vacuum.invalid")]))
        .issuer_name(ca.subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=2))
        .not_valid_after(now - timedelta(days=1) if expired else now + timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("vacuum.invalid")]), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
    )
    if not private:
        builder = builder.add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False
        )
    return builder.sign(ca_key, hashes.SHA256())


def certificate_message(cert, tls13):
    der = cert.public_bytes(serialization.Encoding.DER)
    entry = len(der).to_bytes(3, "big") + der + (b"\0\0" if tls13 else b"")
    return (b"\0" if tls13 else b"") + len(entry).to_bytes(3, "big") + entry


class DreameVacuumPackageTests(unittest.TestCase):
    def test_packaged_source_and_optional_frontend(self):
        root = Path(os.environ["componentPath"]) / "custom_components/dreame_vacuum"
        source = Path(os.environ["sourcePath"]) / "custom_components/dreame_vacuum"
        self.assertEqual(Path(component.__file__).parent, root)
        self.assertFalse((root / "frontend.py").exists())
        for path in root.rglob("*.py"):
            self.assertEqual(path.read_bytes(), (source / path.relative_to(root)).read_bytes())
        self.assertIsNone(component.frontend)
        self.assertIsNone(config_flow.frontend)
        self.assertTrue(asyncio.run(component.async_setup(object(), {})))
        self.assertEqual(sys.version.split()[0], os.environ["pythonVersion"])
        self.assertEqual(importlib.metadata.version("cryptography"), os.environ["cryptographyVersion"])
        self.assertEqual(importlib.metadata.version("mini-racer"), "0.14.1")
        # Check that the bundled private root is the exact reviewed certificate,
        # not the similarly named public GlobalSign root.
        root_ca = x509.load_pem_x509_certificate(protocol.DREAME_MQTT_ROOT_CA)
        self.assertEqual(root_ca.fingerprint(hashes.SHA256()).hex(),
                         "6db9ea84c7e4c9aec692cd540ff52381f5e37dae47df8ebeb948a4461aeae425")
        # Also initialize the real certifi/private stores and ensure neither
        # accepts a generated untrusted certificate (no external CA/network).
        untrusted = leaf_certificate(certificate_authority("Offline untrusted CA"))
        for private_ca in [False, True]:
            client = TLS("vacuum.invalid", 443, "vacuum.invalid", 1, [], private_ca=private_ca)
            with self.assertRaisesRegex(ConnectionError, "certificate verify failed"):
                client._verify_chain(certificate_message(untrusted, True), True)

    def test_ce_models_us_and_frontend_free_options_flow(self):
        flow = config_flow.DreameVacuumFlowHandler()
        flow.account_type = config_flow.ACCOUNT_TYPE_DREAME
        flow.country = "us"
        flow.model = "dreame.vacuum.r2562c"
        flow.load_devices()
        for model in ["r2562c", "r2562k", "r5021c"]:
            self.assertIn(f"dreame.vacuum.{model}", flow.models)
        region_selector = next(v for k, v in flow.login_schema.schema.items() if str(k) == "country")
        self.assertIn("us", region_selector.config["options"])
        flow.async_create_entry = Mock(return_value={"type": "create_entry"})
        result = asyncio.run(flow.async_step_options({"name": "Offline test", "notify": []}))
        self.assertEqual(result, {"type": "create_entry"})
        created = flow.async_create_entry.call_args.kwargs
        self.assertEqual(created["data"]["country"], "us")
        self.assertEqual(created["data"]["account_type"], "dreame")
        self.assertEqual(created["options"]["dvc_key"], "")

    def test_native_v8_and_bundled_map_optimizer(self):
        with MiniRacer() as js:
            self.assertEqual(js.eval("6 * 7"), 42)
            js.eval(base64.b64decode(MAP_OPTIMIZER_JS).decode())
            self.assertEqual(js.eval("typeof optimize"), "function")
            result = js.call("optimize", [[0] * 5 for _ in range(5)], [0, 0, 5, 5, 50], None, None, None)
            self.assertIsInstance(result, list)
            print(f"Native mini-racer 0.14.1 V8 {js.v8_version}: JS and bundled optimizer executed")

    def test_http_and_mqtt_select_separate_trust_policies(self):
        calls = []

        class StopBeforeNetwork(Exception):
            pass

        def capture_socket(*args, **kwargs):
            calls.append(kwargs.get("private_ca", False))
            return SimpleNamespace(connect=Mock(side_effect=StopBeforeNetwork))

        with patch.object(Cloud, "DreameTLSSocket", side_effect=capture_socket):
            http = SimpleNamespace(_strings=[], _http_lock=Lock(), _conns={}, DreameTLSSocket=Cloud.DreameTLSSocket)
            with self.assertRaises(StopBeforeNetwork):
                Cloud._http(http, "GET", "https://vacuum.invalid/", {}, None, 1)
            mqtt = SimpleNamespace(_host="vacuum.invalid", _port=8883, _connect_timeout=1,
                                   _userdata=SimpleNamespace(_strings=[]))
            with self.assertRaises(StopBeforeNetwork):
                Cloud.DreameClient._create_socket_connection(mqtt)
        self.assertEqual(calls, [False, True])

    def test_certificate_chain_hostname_validity_and_trust_separation(self):
        public = certificate_authority("Test public CA")
        private = certificate_authority("Test private MQTT CA", private=True)
        untrusted = certificate_authority("Untrusted CA")
        public_leaf = leaf_certificate(public)
        private_leaf = leaf_certificate(private, private=True)
        # Substitute only trust anchors with generated fixtures; execute the
        # packaged verification/parsing and public/private extension policies.
        with patch.object(TLS, "_store", Store([public[1]])), \
             patch.object(TLS, "_private_policy", None), \
             patch.object(protocol, "DREAME_MQTT_ROOT_CA", private[1].public_bytes(serialization.Encoding.PEM)):
            for tls13 in [False, True]:
                for private_ca, trusted in [(False, public_leaf), (True, private_leaf)]:
                    with self.subTest(tls13=tls13, private_ca=private_ca):
                        client = TLS("vacuum.invalid", 443, "vacuum.invalid", 1, [], private_ca=private_ca)
                        client._verify_chain(certificate_message(trusted, tls13), tls13)
                        for bad in [leaf_certificate(untrusted), leaf_certificate(private if private_ca else public,
                                    expired=True, private=private_ca), public_leaf if private_ca else private_leaf]:
                            with self.assertRaisesRegex(ConnectionError, "certificate verify failed"):
                                client._verify_chain(certificate_message(bad, tls13), tls13)
                        client._sni = "wrong.invalid"
                        with self.assertRaisesRegex(ConnectionError, "certificate verify failed"):
                            client._verify_chain(certificate_message(trusted, tls13), tls13)

    def test_handshake_signature_rejection_and_finished_guards(self):
        key = ec.generate_private_key(ec.SECP256R1())
        data = b"offline handshake transcript"
        signature = key.sign(data, ec.ECDSA(hashes.SHA256()))
        TLS._verify_signature(key.public_key(), 0x0403, signature, data)
        for scheme, sig, message in [(0x0403, signature, data + b"changed"),
                                     (0x0403, b"invalid", data), (0xFFFF, signature, data)]:
            with self.assertRaisesRegex(ConnectionError, "server signature verify failed"):
                TLS._verify_signature(key.public_key(), scheme, sig, message)
        # Bounded source regression for the Finished guards, not a simulated
        # complete handshake or a claim of strict handshake-message ordering.
        tls13 = inspect.getsource(TLS._handshake)
        tls12 = inspect.getsource(TLS._handshake_tls12)
        self.assertIn("not cert_verified or not hmac.compare_digest(msg[4:], expected)", tls13)
        self.assertIn("hmac.compare_digest(self._decrypt12(22, body)", tls12)
        self.assertIn("if ske is None or cert_key is None:", tls12)


if __name__ == "__main__":
    unittest.main(verbosity=2)
