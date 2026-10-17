#!/usr/bin/env python3
"""A local stand-in for GitHub's releases, for the installer tests (standard library only).

It serves fixture releases the way GitHub does, at the paths install.sh and install.ps1 use:

  /api/repos/<owner>/<repo>/releases/latest            release JSON (tag_name, assets[url,id,name,digest,...])
  /api/repos/<owner>/<repo>/releases/tags/<tag>        the same, for one tag
  /api/repos/<owner>/<repo>/releases/assets/<id>       with Accept: application/octet-stream, 302 to /storage/...
  /web/<owner>/<repo>/releases/latest                  302 to /web/<owner>/<repo>/releases/tag/<tag>
  /web/<owner>/<repo>/releases/download/<tag>/<name>   302 to /storage/...
  /storage/<tag>/<name>                                the file, at http://localhost:<port> (another host name, like GitHub's storage host)

Fixtures: <root>/<tag>/<files>; the latest release is the highest version. A file named
`digest-override` in a tag holds "<asset> <sha256>" lines that replace GitHub's digest for an asset.

--private makes it behave like an internal repo: the API and web paths answer 404 unless the request
carries `Authorization: Bearer <--token>`. Every request is logged to --log as
"<path> auth=<yes|no>", so the tests can check where the token was sent.

  python3 fake_github.py --root DIR --port 0 --port-file FILE --log FILE [--private --token T]
"""
import argparse
import hashlib
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def version_key(tag):
    nums = re.findall(r"\d+", tag)
    return tuple(int(n) for n in nums[:3])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--private", action="store_true")
    ap.add_argument("--token", default="")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    def tags():
        return sorted((t for t in os.listdir(root) if os.path.isdir(os.path.join(root, t))), key=version_key)

    def assets(tag, base):
        d = os.path.join(root, tag)
        overrides = {}
        op = os.path.join(d, "digest-override")
        if os.path.exists(op):
            for line in open(op, encoding="utf-8"):
                name, _, digest = line.strip().partition(" ")
                overrides[name] = digest
        out = []
        for i, name in enumerate(sorted(os.listdir(d))):
            if name == "digest-override":
                continue
            with open(os.path.join(d, name), "rb") as f:
                digest = "sha256:" + hashlib.sha256(f.read()).hexdigest()
            digest = overrides.get(name, digest)
            aid = version_key(tag)[0] * 1000000 + version_key(tag)[1] * 10000 + version_key(tag)[2] * 100 + i
            out.append({
                "url": f"{base}/api/repos/gizmodata/hardcharger/releases/assets/{aid}",
                "id": aid,
                "name": name,
                "uploader": {"login": "github-actions[bot]", "id": 41898282, "url": "https://api.github.com/users/github-actions%5Bbot%5D"},
                "content_type": "application/gzip",
                "size": os.path.getsize(os.path.join(d, name)),
                "digest": digest if digest != "null" else None,
                "browser_download_url": f"{base}/web/gizmodata/hardcharger/releases/download/{tag}/{name}",
            })
        return out

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body=b"", ctype="application/json", headers=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            auth = self.headers.get("Authorization", "")
            path = self.path.split("?")[0]
            with open(args.log, "a", encoding="utf-8") as log:
                log.write(f"{path} auth={'yes' if auth else 'no'}\n")
            base = f"http://127.0.0.1:{self.server.server_address[1]}"
            # Storage is another host name, as on GitHub, so clients must drop the Authorization header.
            storage = f"http://localhost:{self.server.server_address[1]}"
            if path.startswith("/storage/"):
                _, _, tag, name = path.split("/", 3)
                f = os.path.join(root, tag, name)
                return self.send(200, open(f, "rb").read(), "application/octet-stream") if os.path.isfile(f) else self.send(404, b"{}")
            if args.private and auth != f"Bearer {args.token}":
                return self.send(404, b'{"message": "Not Found"}')
            m = re.fullmatch(r"/api/repos/gizmodata/hardcharger/releases/(latest|tags/([^/]+)|assets/(\d+))", path)
            if m:
                if m.group(3):
                    aid = int(m.group(3))
                    for tag in tags():
                        for a in assets(tag, base):
                            if a["id"] == aid:
                                if "application/octet-stream" in self.headers.get("Accept", ""):
                                    return self.send(302, b"", headers={"Location": f"{storage}/storage/{tag}/{a['name']}?sig=x"})
                                return self.send(200, json.dumps(a).encode())
                    return self.send(404, b'{"message": "Not Found"}')
                tag = tags()[-1] if m.group(1) == "latest" and tags() else m.group(2)
                if not tag or tag not in tags():
                    return self.send(404, b'{"message": "Not Found"}')
                body = {"url": f"{base}/api/repos/gizmodata/hardcharger/releases/1", "id": 1,
                        "author": {"login": "github-actions[bot]", "id": 41898282},
                        "tag_name": tag, "name": tag, "body": 'Notes with "quotes", {braces} and "name": "trap",',
                        "assets": assets(tag, base)}
                return self.send(200, json.dumps(body, indent=2).encode())
            m = re.fullmatch(r"/web/gizmodata/hardcharger/releases/(latest|tag/([^/]+)|download/([^/]+)/([^/]+))", path)
            if m:
                if m.group(1) == "latest":
                    return self.send(302, b"", "text/html", {"Location": f"{base}/web/gizmodata/hardcharger/releases/tag/{tags()[-1]}"}) if tags() else self.send(404, b"")
                if m.group(2):
                    return self.send(200, b"<html>release</html>", "text/html") if m.group(2) in tags() else self.send(404, b"")
                tag, name = m.group(3), m.group(4)
                if os.path.isfile(os.path.join(root, tag, name)):
                    return self.send(302, b"", "text/html", {"Location": f"{storage}/storage/{tag}/{name}?sig=x"})
                return self.send(404, b"Not Found", "text/plain")
            return self.send(404, b'{"message": "Not Found"}')

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    with open(args.port_file, "w", encoding="utf-8") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
