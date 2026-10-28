"""Exercise the configured Serve CLI with only a private, fake LocalAPI socket."""
import copy
import http.server
import json
import os
import shlex
import socketserver
import subprocess
import tempfile
import threading


# Representative node listeners and a different Service must survive publication.
initial_config = {
    "TCP": {"8443": {"HTTPS": True}, "9443": {"HTTPS": True}},
    "Web": {
        "luminous-lemon.tail32462.ts.net:8443": {
            "Handlers": {"/allegra": {"Proxy": "http://127.0.0.1:8765"}}
        },
        "luminous-lemon.tail32462.ts.net:9443": {
            "Handlers": {"/": {"Proxy": "http://127.0.0.1:6080"}}
        },
    },
    "Foreground": {"test-session": {"TCP": {"443": {"HTTPS": True}}}},
    "Services": {"svc:other": {"TCP": {"5432": {"TCPForward": "127.0.0.1:5432"}}}},
}
initial_prefs = {
    "AdvertiseServices": ["svc:other"], "RunSSH": True,
    "CorpDNS": True, "RouteAll": False,
}
state = {
    "config": copy.deepcopy(initial_config),
    "prefs": copy.deepcopy(initial_prefs),
    "tags": [],
    "writes": [],
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/localapi/v0/serve-config":
            self.respond(state["config"])
        elif self.path == "/localapi/v0/prefs":
            self.respond(state["prefs"])
        elif self.path == "/localapi/v0/status?peers=false":
            self.respond({
                "BackendState": "Running",
                "Self": {
                    "DNSName": "luminous-lemon.tail32462.ts.net.",
                    "Tags": state["tags"],
                },
                "CurrentTailnet": {"MagicDNSSuffix": "tail32462.ts.net"},
            })
        else:
            self.send_error(500, "Unexpected API read")

    def body(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            chunks = []
            while size := int(self.rfile.readline().strip(), 16):
                chunks.append(self.rfile.read(size))
                assert self.rfile.read(2) == b"\r\n"
            assert self.rfile.readline() == b"\r\n"
            return json.loads(b"".join(chunks))
        return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

    def do_PATCH(self):
        assert self.path == "/localapi/v0/prefs", self.path
        prefs = self.body()
        assert {k for k, v in prefs.items() if k.endswith("Set") and v} == {
            "AdvertiseServicesSet"
        }, prefs
        state["writes"].append("advertise")
        state["prefs"]["AdvertiseServices"] = prefs["AdvertiseServices"]
        self.respond(state["prefs"])

    def do_POST(self):
        assert self.path == "/localapi/v0/serve-config", self.path
        state["writes"].append("serve")
        state["config"] = self.body()
        self.respond({})


class Server(socketserver.UnixStreamServer):
    pass


with tempfile.TemporaryDirectory() as directory:
    socket_path = os.path.join(directory, "fake-tailscaled.sock")
    with Server(socket_path, Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command = shlex.split(os.environ["publicationCommand"])
        # Every invocation explicitly uses this fake socket, never /run/tailscale.
        command.insert(1, "--socket=" + socket_path)
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=15)
            assert result.returncode != 0, result.stdout
            assert "service hosts must be tagged nodes" in result.stderr, result.stderr
            assert state["writes"] == []
            assert state["config"] == initial_config
            assert state["prefs"] == initial_prefs

            state["tags"] = ["tag:test-host"]  # Fake identity, not a proposed policy tag.
            for _ in range(2):
                result = subprocess.run(command, capture_output=True, text=True, timeout=15)
                assert result.returncode == 0, result.stdout + result.stderr
                config = copy.deepcopy(state["config"])
                service = config["Services"].pop("svc:ha")
                assert config == initial_config, config
                assert service == {
                    "TCP": {"80": {"HTTP": True}},
                    "Web": {"ha.tail32462.ts.net:80": {
                        "Handlers": {"/": {"Proxy": "http://127.0.0.1:8123"}}
                    }},
                }, service
                assert state["prefs"] == {
                    **initial_prefs, "AdvertiseServices": ["svc:other", "svc:ha"]
                }, state["prefs"]
            assert state["writes"] == ["advertise", "serve", "serve"]
        finally:
            server.shutdown()
            thread.join()

print("Pinned Serve CLI: untagged rejection, svc:ha HTTP route, idempotence, other listeners/ads/prefs preserved; fake socket only")
