#!/usr/bin/env python3
# Minimal RFC 8693 (OAuth 2.0 Token Exchange) STS + a mock "MCP gateway" listener,
# pure Python stdlib (no pip). ISOLATED demo path for Stream S3 — it does NOT touch the
# production mcp-gateway/Authorino. It proves: a SPIRE JWT-SVID (subject_token) is
# cryptographically verified against the SPIRE OIDC JWKS and exchanged for an access
# token that the gateway listener accepts.
#
#   POST /token  grant_type=urn:ietf:params:oauth:grant-type:token-exchange
#                subject_token=<JWT-SVID> subject_token_type=.../jwt
#                audience=parasol-mcp-gateway
#     -> verifies the SVID (RS256 against JWKS), returns access_token (HS256, our STS).
#   GET  /mcp    Authorization: Bearer <access_token>
#     -> validates the exchanged token (aud=parasol-mcp-gateway, iss=our STS); 200 or 401.
#
# ponytail: HS256 for the issued token (shared secret, STS==gateway here) and SVID verify
# via hand-rolled PKCS#1 v1.5 — both keep this to stdlib. Production uses the real gateway's
# JWT validation (Keycloak/Authorino) and an asymmetric STS key.
import base64, hashlib, hmac, json, os, ssl, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

JWKS_URL   = os.environ.get("SPIRE_JWKS_URL", "https://oidc-discovery.apps.cluster-znh6n.dyn.redhatworkshops.io/keys")
SPIRE_ISS  = os.environ.get("SPIRE_ISSUER",  "https://oidc-discovery.apps.cluster-znh6n.dyn.redhatworkshops.io")
EXPECT_AUD = os.environ.get("EXPECT_SUBJECT_AUD", "parasol-sts")      # audience the SVID must carry
STS_ISS    = os.environ.get("STS_ISSUER", "https://parasol-sts.local")
TARGET_AUD = os.environ.get("TARGET_AUDIENCE", "parasol-mcp-gateway") # aud of the issued token
STS_SECRET = os.environ.get("STS_SECRET", "parasol-sts-demo-signing-key").encode()
SHA256_DIGESTINFO = bytes.fromhex("3031300d060960864801650304020105000420")

def b64url_dec(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
def b64url_enc(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def fetch_jwks():
    try:
        ctx = ssl.create_default_context()
        return json.load(urllib.request.urlopen(JWKS_URL, timeout=10, context=ctx))
    except Exception as e:
        print("JWKS verified fetch failed (%s); retrying without TLS verify" % e, flush=True)
        ctx = ssl._create_unverified_context()
        return json.load(urllib.request.urlopen(JWKS_URL, timeout=10, context=ctx))

def rsa_verify(signing_input, sig, n, e):
    k = (n.bit_length() + 7) // 8
    m = pow(int.from_bytes(sig, "big"), e, n)
    em = m.to_bytes(k, "big")
    h = hashlib.sha256(signing_input).digest()
    t = SHA256_DIGESTINFO + h
    expected = b"\x00\x01" + b"\xff" * (k - 3 - len(t)) + b"\x00" + t
    return hmac.compare_digest(em, expected)

def verify_svid(token):
    h, p, s = token.split(".")
    hdr = json.loads(b64url_dec(h)); payload = json.loads(b64url_dec(p))
    kid = hdr.get("kid")
    key = next((k for k in fetch_jwks()["keys"] if k.get("kid") == kid), None)
    if not key: raise ValueError("no JWKS key for kid %s" % kid)
    n = int.from_bytes(b64url_dec(key["n"]), "big"); e = int.from_bytes(b64url_dec(key["e"]), "big")
    if not rsa_verify(("%s.%s" % (h, p)).encode(), b64url_dec(s), n, e):
        raise ValueError("SVID signature invalid")
    if payload.get("iss") != SPIRE_ISS: raise ValueError("bad iss %s" % payload.get("iss"))
    aud = payload.get("aud"); aud = aud if isinstance(aud, list) else [aud]
    if EXPECT_AUD not in aud: raise ValueError("SVID aud %s lacks %s" % (aud, EXPECT_AUD))
    if payload.get("exp", 0) < time.time(): raise ValueError("SVID expired")
    return payload["sub"]  # spiffe://...

def mint(sub):
    hdr = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    body = {"iss": STS_ISS, "aud": TARGET_AUD, "sub": sub, "iat": now, "exp": now + 300,
            "act": {"sub": "urn:parasol:sts"}}
    si = (b64url_enc(json.dumps(hdr).encode()) + "." + b64url_enc(json.dumps(body).encode())).encode()
    sig = hmac.new(STS_SECRET, si, hashlib.sha256).digest()
    return (si + b"." + b64url_enc(sig).encode()).decode()

def check_access(token):
    h, p, s = token.split(".")
    si = ("%s.%s" % (h, p)).encode()
    if not hmac.compare_digest(b64url_dec(s), hmac.new(STS_SECRET, si, hashlib.sha256).digest()):
        raise ValueError("bad signature")
    payload = json.loads(b64url_dec(p))
    if payload.get("iss") != STS_ISS or payload.get("aud") != TARGET_AUD: raise ValueError("bad iss/aud")
    if payload.get("exp", 0) < time.time(): raise ValueError("expired")
    return payload

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, fmt, *a): print("%s - %s" % (self.address_string(), fmt % a), flush=True)
    def do_GET(self):
        if self.path.split("?")[0] == "/mcp":
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                return self._send(401, {"error": "missing bearer token"})
            try:
                claims = check_access(auth[7:])
            except Exception as e:
                return self._send(401, {"error": "token rejected", "detail": str(e)})
            return self._send(200, {"result": "MCP gateway accepted the exchanged token",
                                    "workload_identity": claims["sub"], "aud": claims["aud"]})
        if self.path == "/healthz": return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})
    def do_POST(self):
        if self.path.split("?")[0] != "/token": return self._send(404, {"error": "not found"})
        q = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        g = q.get("grant_type", [""])[0]
        if g != "urn:ietf:params:oauth:grant-type:token-exchange":
            return self._send(400, {"error": "unsupported_grant_type"})
        st = q.get("subject_token", [""])[0]
        try:
            sub = verify_svid(st)
        except Exception as e:
            return self._send(401, {"error": "invalid_subject_token", "detail": str(e)})
        print("exchanged subject %s" % sub, flush=True)
        return self._send(200, {"access_token": mint(sub), "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                                "token_type": "Bearer", "expires_in": 300})

if __name__ == "__main__":
    print("STS up on :8080 (jwks=%s, target_aud=%s)" % (JWKS_URL, TARGET_AUD), flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
