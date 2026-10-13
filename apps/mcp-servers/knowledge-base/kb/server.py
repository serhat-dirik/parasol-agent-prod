"""Parasol knowledge-base MCP server: one tool, search_knowledge(query), over pgvector.

Secured (KB_ENFORCE=true): the caller is the token the MCP gateway forwards - the agent's on-behalf-of
token (sub/preferred_username = the user, azp = the agent). It is verified against Keycloak's JWKS
(signature, issuer, expiry, audience = this server's Keycloak client); its "groups" claim decides which
documents may be searched. Two independent filters: the query's WHERE audience && groups, and
PostgreSQL row-level security on the same rows (the server sets the groups per transaction; its role
cannot bypass RLS). No valid token -> the tool refuses (deny by default; never public-only, so a
misrouted call is visible as an error rather than a quietly smaller answer).
Free (KB_ENFORCE=false): no identity, no filter, RLS off in the database: everything is searchable.
"""
import json
import logging
import os
import threading
from collections import Counter

import jwt
import psycopg
from mcp.server.fastmcp import Context, FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from opentelemetry import propagate, trace
from prometheus_client import CONTENT_TYPE_LATEST, Counter as PCounter, generate_latest
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from common import embed, vec

log = logging.getLogger("knowledge-base")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

ENFORCE = os.environ.get("KB_ENFORCE", "false").lower() == "true"
ENV = os.environ.get("KB_ENV", "dev")
DSN = os.environ.get("KB_DSN", "")
# the realm the caller's token must come from: https://sso.apps.<domain>/realms/parasol
ISSUER = os.environ.get("KB_ISSUER") or os.environ.get("KB_TOKEN_URL", "").split("/protocol/")[0]
AUDIENCE_CLIENT = os.environ.get("KB_AUDIENCE", "parasol-secured/knowledge-base")
AGENTS = set(os.environ.get("KB_AGENTS", "parasol-claims-agent").split(","))
TOP_K = int(os.environ.get("KB_TOP_K", "4"))
# A withheld match counts only when it is a real competitor for the answer: similarity >= KB_MIN_SCORE and
# within KB_WITHHELD_MARGIN of the best match overall (granite similarities sit high, ~0.7 for unrelated text).
MIN_SCORE = float(os.environ.get("KB_MIN_SCORE", "0.75"))
MARGIN = float(os.environ.get("KB_WITHHELD_MARGIN", "0.06"))

RETRIEVALS = PCounter("parasol_rag_retrievals", "Knowledge-base searches", ["user", "agent", "env"])
WITHHELD = PCounter("parasol_rag_withheld", "Passages withheld from a caller", ["classification", "user", "agent", "env"])
RESTRICTED = PCounter("parasol_rag_restricted_access", "Restricted documents returned", ["doc_id", "user", "agent", "env"])
tracer = trace.get_tracer("knowledge-base")
# Signing keys from where the realm is reached (KB_TOKEN_URL: Keycloak's in-cluster address in secured, trusted via
# SSL_CERT_FILE = the service CA); the issuer the tokens carry stays the public KB_ISSUER.
REALM_URL = os.environ.get("KB_TOKEN_URL", "").split("/protocol/")[0] or ISSUER
_jwks = jwt.PyJWKClient(REALM_URL + "/protocol/openid-connect/certs", cache_keys=True) if ENFORCE else None
_lock = threading.Lock()   # ponytail: one embedding at a time on a CPU pod; a pool if queries ever overlap


class Caller:
    def __init__(self, user="anonymous", agent="none", groups=()):
        self.user, self.agent, self.groups = user, agent, sorted({g.lstrip("/") for g in groups})


def verify(authorization: str | None) -> Caller:
    """The forwarded on-behalf-of token, verified. Raises ValueError (-> tool error) when it is not acceptable."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise ValueError("no caller identity: the knowledge base answers only on behalf of a signed-in user")
    token = authorization.split(" ", 1)[1].strip()
    try:
        key = _jwks.get_signing_key_from_jwt(token).key
        c = jwt.decode(token, key, algorithms=["RS256"], issuer=ISSUER, audience=AUDIENCE_CLIENT,
                       options={"require": ["exp", "iss", "sub"]})
    except jwt.PyJWTError as e:
        raise ValueError(f"caller token rejected: {e}") from None
    if c.get("azp") not in AGENTS:
        raise ValueError(f"not via an approved agent (azp={c.get('azp')})")
    return Caller(c.get("preferred_username") or c["sub"], c["azp"], c.get("groups") or [])


def search(query: str, caller: Caller):
    q = vec(embed([query])[0])
    with psycopg.connect(DSN) as conn, conn.transaction():
        if ENFORCE:
            # RLS input for THIS transaction only (is_local=true): the caller's groups, nothing else.
            conn.execute("SELECT set_config('kb.groups', %s, true)", [",".join(caller.groups)])
            rows = conn.execute(
                "SELECT doc_id, title, classification, content, 1 - (embedding <=> %s::vector) FROM chunks "
                "WHERE audience && %s::text[] ORDER BY embedding <=> %s::vector LIMIT %s",
                [q, caller.groups, q, TOP_K]).fetchall()
            cand = conn.execute("SELECT doc_id, classification, score FROM kb_withheld(%s::vector, %s::text[], %s, %s)",
                                [q, caller.groups, TOP_K, MIN_SCORE]).fetchall()
            best = max([r[4] for r in rows] + [c[2] for c in cand], default=0)
            withheld = [(d, c) for d, c, s in cand if s >= best - MARGIN]
        else:
            rows = conn.execute(
                "SELECT doc_id, title, classification, content, 1 - (embedding <=> %s::vector) FROM chunks "
                "ORDER BY embedding <=> %s::vector LIMIT %s", [q, q, TOP_K]).fetchall()
            withheld = []
    return rows, withheld


def answer(rows, withheld):
    counts = Counter(c for _, c in withheld)
    out = {
        "passages": [{"doc_id": d, "title": t, "classification": c, "score": round(s, 3), "snippet": text}
                     for d, t, c, text, s in rows],
        "withheld": {"count": len(withheld), "classifications": dict(counts)},
    }
    if withheld:
        out["note"] = (f"{len(withheld)} matching passage(s) classified {', '.join(sorted(counts))} were withheld: "
                       "the user is not entitled to read them. Do not guess or describe their content.")
    return out


mcp = FastMCP("knowledge-base", host="0.0.0.0", port=8080, stateless_http=True, json_response=True,
              transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))


@mcp.tool()
def search_knowledge(query: str, ctx: Context) -> str:
    """Search Parasol's internal knowledge base (claims process, policy FAQs, claims handling guidelines,
    repair-vendor rate card, escalation process, staff and HR matters). Returns cited passages (doc_id,
    title, classification, snippet) the user is entitled to read, and how many matching passages were
    withheld. Answer only from the returned passages and cite their titles."""
    headers = ctx.request_context.request.headers
    caller = verify(headers.get("authorization")) if ENFORCE else Caller()
    with tracer.start_as_current_span("tool.search_knowledge", context=propagate.extract(dict(headers)),
                                      kind=trace.SpanKind.SERVER) as span:
        with _lock:
            rows, withheld = search(query, caller)
        out = answer(rows, withheld)
        returned = sorted({r[0] for r in rows})
        span.set_attributes({
            "enduser.id": caller.user, "gen_ai.agent.name": caller.agent, "deployment.environment": ENV,
            "rag.query": query, "rag.returned_doc_ids": returned,
            "rag.returned_classifications": sorted({r[2] for r in rows}),
            "rag.withheld_count": len(withheld),
            "rag.withheld_classifications": sorted(out["withheld"]["classifications"]),
        })
    RETRIEVALS.labels(caller.user, caller.agent, ENV).inc()
    for doc in sorted({r[0] for r in rows if r[2] == "restricted"}):
        RESTRICTED.labels(doc, caller.user, caller.agent, ENV).inc()
        log.info("RAG restricted doc=%s accessed by %s via %s", doc, caller.user, caller.agent)
    for (doc, cls), n in sorted(Counter(withheld).items()):
        WITHHELD.labels(cls, caller.user, caller.agent, ENV).inc(n)
        log.info("RAG withheld doc=%s classification=%s passages=%d from %s via %s", doc, cls, n, caller.user, caller.agent)
    log.info("RAG search user=%s agent=%s env=%s returned=%s withheld=%d", caller.user, caller.agent, ENV,
             returned, len(withheld))
    return json.dumps(out)


@mcp.custom_route("/metrics", methods=["GET"])
async def metrics(_: Request):
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request):
    return JSONResponse({"status": "ok", "enforce": ENFORCE})


def tracing():
    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    p = TracerProvider(resource=Resource.create({"service.name": "knowledge-base"}))
    p.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(insecure=True)))
    trace.set_tracer_provider(p)


if __name__ == "__main__":
    tracing()
    embed(["warm-up"])   # load the model before the first call
    log.info("knowledge-base enforce=%s env=%s", ENFORCE, ENV)
    mcp.run(transport="streamable-http")
