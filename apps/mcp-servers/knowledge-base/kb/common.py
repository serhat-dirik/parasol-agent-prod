"""Shared by the server and the ingestion job: the documents, how they are chunked, who may read them,
and the embedding model (IBM Granite embedding, baked into the image at build time)."""
import os
import pathlib
import re

DOCS = pathlib.Path(__file__).parent / "docs"
MODEL = os.environ.get("KB_MODEL", "ibm-granite/granite-embedding-125m-english")
DIM = 768

# Who may read each classification: Keycloak group names (the token's "groups" claim).
AUDIENCE = {
    "public": ["adjusters", "claims-managers", "contractors", "developers"],
    "internal": ["adjusters", "claims-managers"],
    "restricted": ["claims-managers"],
}


def load_docs():
    """Each file: 'key: value' header lines, '---', then paragraphs."""
    docs = []
    for f in sorted(DOCS.glob("*.md")):
        head, _, body = f.read_text().partition("\n---\n")
        meta = dict(line.split(": ", 1) for line in head.strip().splitlines())
        assert meta["classification"] in AUDIENCE, f
        docs.append({**meta, "body": body.strip()})
    return docs


def chunks(doc, size=700):
    """Paragraphs packed into chunks of at most ~size characters (a paragraph is never split)."""
    out, cur = [], ""
    for p in re.split(r"\n\s*\n", doc["body"]):
        if cur and len(cur) + len(p) > size:
            out.append(cur)
            cur = ""
        cur = (cur + "\n\n" + p).strip()
    if cur:
        out.append(cur)
    return out


_model = None


def embed(texts):
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer(MODEL, device="cpu")
    return [v.tolist() for v in _model.encode(texts, normalize_embeddings=True)]


def vec(v):
    return "[" + ",".join(f"{x:.6f}" for x in v) + "]"
