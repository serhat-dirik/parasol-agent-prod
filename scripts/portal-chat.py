#!/usr/bin/env python3
"""portal-chat.py: drive a Parasol portal the way the browser does, without a browser (scripts/regression.sh).

Logs in as a demo persona through the portal's own OIDC code flow (Keycloak login page, the demo
login of scripts/token.sh), then either sends ONE chat message over the portal's WebSocket /ws/query with the claim
the user is viewing ({claimNumber, query}, a new connection = a fresh conversation), or GETs a portal REST path
(the screens' reads, e.g. /api/claims/CLM-1029). Prints JSON; standard library only.

  portal-chat.py <host> <user> ask "<message>" [CLM-1001]   -> {"tools": [...], "propose": ..., "guardrail": ...,
                                                               "answer": ..., "error": ..., "trace": ...}
  portal-chat.py <host> <user> get /api/claims/CLM-1029     -> {"status": 403, "body": ...}
"""
import base64, http.cookiejar, html, json, os, re, socket, ssl, struct, sys, urllib.error, urllib.parse, urllib.request

CTX = ssl._create_unverified_context()   # lab cluster: router certificates are self-signed


def login(host, user):
    """Code flow as a browser does it: portal -> Keycloak login form -> portal callback; returns the cookie jar."""
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler(context=CTX))
    page = op.open(f"https://{host}/", timeout=30).read().decode()
    m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page) or re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
    if not m:
        sys.exit(f"no Keycloak login form behind https://{host}/ (already a session, or the portal is not OIDC)")
    # Demo personas log in with their user name (scripts/token.sh); the field names are Keycloak's login form.
    form = urllib.parse.urlencode({"username": user, "password": user, "credentialId": ""}).encode()
    after = op.open(html.unescape(m.group(1)), data=form, timeout=30)
    if "kc-form-login" in after.read().decode(errors="replace"):
        sys.exit(f"login as {user} refused by Keycloak")
    return op, jar


def ws_ask(host, jar, query, claim=None, timeout=240):
    """One chat turn over wss://host/ws/query; returns the frames until 'done'."""
    cookie = "; ".join(f"{c.name}={c.value}" for c in jar if host.endswith(c.domain.lstrip(".")) or c.domain == host)
    raw = socket.create_connection((host, 443), timeout=timeout)
    s = CTX.wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /ws/query HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: https://{host}\r\n"
               f"Cookie: {cookie}\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("WebSocket handshake: connection closed")
        buf += chunk
    head, buf = buf.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        sys.exit("WebSocket handshake refused: " + head.split(b"\r\n", 1)[0].decode())
    payload = json.dumps({"claimNumber": claim or "", "query": query}).encode()
    mask = os.urandom(4)
    n = len(payload)
    hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack("!H", n) if n < 65536
                           else bytes([0x80 | 127]) + struct.pack("!Q", n))
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def need(k):
        nonlocal buf
        while len(buf) < k:
            chunk = s.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        out, buf = buf[:k], buf[k:]
        return out
    frames, msg = [], b""
    while True:
        b0, b1 = need(2)
        ln = b1 & 0x7F
        ln = struct.unpack("!H", need(2))[0] if ln == 126 else struct.unpack("!Q", need(8))[0] if ln == 127 else ln
        data = need(ln)
        op = b0 & 0x0F
        if op == 8:
            break
        if op in (1, 0):
            msg += data
            if b0 & 0x80:
                f = json.loads(msg)
                msg = b""
                if f.get("type") == "done":
                    break
                frames.append(f)
    s.close()
    return frames


def summary(frames):
    """The frames as the chat renders them: chips, propose card, guardrail banner, answer or error, trace link."""
    pick = lambda t: [f for f in frames if f["type"] == t]
    one = lambda t, k="text": (pick(t)[0].get(k) if pick(t) else None)
    return {"tools": [{"tool": f["text"], "args": f.get("data")} for f in pick("tool")],
            "propose": ({"claim": one("propose"), **json.loads(one("propose", "data") or "{}")} if pick("propose") else None),
            "guardrail": one("guardrail"), "mask": one("mask"), "answer": one("answer"), "error": one("error"),
            "trace": one("trace")}


if __name__ == "__main__":
    if len(sys.argv) < 5 or sys.argv[3] not in ("ask", "get"):
        sys.exit(__doc__)
    host, user, cmd = sys.argv[1:4]
    op, jar = login(host, user)
    if cmd == "ask":
        print(json.dumps(summary(ws_ask(host, jar, sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else None))))
    else:
        try:
            r = op.open(f"https://{host}{sys.argv[4]}", timeout=60)
            status, body = r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read().decode()
        try:
            body = json.loads(body)
        except ValueError:
            pass
        print(json.dumps({"status": status, "body": body}))
