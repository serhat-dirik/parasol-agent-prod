"""Policy-document RAG for the Parasol assistant.

Ingestion: Docling parses the Parasol policy PDF into Markdown; that plus the seeded
policy corpus is chunked, embedded via the nomic-embed CPU endpoint, and kept in an
in-memory vector store. A question is answered by embedding it, retrieving the nearest
chunks (cosine), and asking llama-scout (MaaS) to answer grounded ONLY in those chunks.

ponytail: in-memory numpy cosine store, not pgvector/Milvus — the corpus is tiny and
fixed; swap in a persistent vector DB when the corpus outgrows memory.
"""
import json
import os
import time

import numpy as np
import requests
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

EMBED_URL = os.environ["EMBED_URL"]
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
PDF_PATH = os.environ.get("PDF_PATH", "/data/policy-info.pdf")
CORPUS_PATH = os.environ.get("CORPUS_PATH", "/app/corpus.json")
MAAS_MODEL = os.environ.get("MAAS_MODEL", "llama-scout-17b")

STORE = {"chunks": [], "matrix": None, "dim": 0, "pdf_source": "pending"}


def embed(texts, prefix):
    """Embed via the Ollama nomic-embed endpoint with the v1.5 task prefix.

    Returns L2-normalized vectors so a dot product equals cosine similarity; retries
    while the embedding model warms up / is still being pulled.
    """
    payload = {"model": EMBED_MODEL, "input": [f"{prefix}{t}" for t in texts]}
    last = None
    for attempt in range(60):
        try:
            r = requests.post(EMBED_URL, json=payload, timeout=120)
            r.raise_for_status()
            arr = np.array(r.json()["embeddings"], dtype=np.float32)
            arr /= np.linalg.norm(arr, axis=1, keepdims=True) + 1e-9
            return arr, int(arr.shape[1])
        except Exception as e:  # noqa: BLE001 - startup wait loop
            last = e
            print(f"[rag] embed endpoint not ready ({e}); retry {attempt+1}/60", flush=True)
            time.sleep(10)
    raise RuntimeError(f"embed endpoint never came up: {last}")


def docling_pdf_chunks():
    """Parse the policy PDF with Docling into heading/paragraph chunks."""
    from docling.document_converter import DocumentConverter

    print(f"[rag] Docling converting {PDF_PATH} ...", flush=True)
    md = DocumentConverter().convert(PDF_PATH).document.export_to_markdown()
    STORE["pdf_source"] = "docling"
    print(f"[rag] Docling produced {len(md)} chars of markdown", flush=True)
    chunks, buf = [], []
    for line in md.splitlines():
        if line.strip():
            buf.append(line.strip())
        elif buf:
            chunks.append(" ".join(buf))
            buf = []
    if buf:
        chunks.append(" ".join(buf))
    # merge tiny fragments so each chunk carries enough context
    merged, cur = [], ""
    for c in chunks:
        cur = f"{cur} {c}".strip() if cur else c
        if len(cur) > 240:
            merged.append(cur)
            cur = ""
    if cur:
        merged.append(cur)
    return [
        {"id": f"policy-info.pdf#{i+1}", "title": "Parasol Auto Policy Document (PDF)",
         "text": t, "source": "policy-info.pdf (Docling)"}
        for i, t in enumerate(merged)
    ]


def ingest():
    chunks = []
    try:
        chunks += docling_pdf_chunks()
    except Exception as e:  # noqa: BLE001
        print(f"[rag] Docling failed ({e}); PDF skipped, corpus still ingested", flush=True)
        STORE["pdf_source"] = f"failed: {e}"
    with open(CORPUS_PATH) as f:
        for d in json.load(f):
            chunks.append({"id": d["id"], "title": d["title"], "text": d["text"],
                           "source": "seeded policy corpus"})
    texts = [f"{c['title']}. {c['text']}" for c in chunks]
    matrix, dim = embed(texts, "search_document: ")
    STORE.update(chunks=chunks, matrix=matrix, dim=dim)
    print(f"[rag] vector store populated: {len(chunks)} chunks, dim={dim}, "
          f"pdf_source={STORE['pdf_source']}", flush=True)


app = FastAPI()


@app.on_event("startup")
def _startup():
    ingest()


def retrieve(query, k=4):
    qv, _ = embed([query], "search_query: ")
    sims = STORE["matrix"] @ qv[0]
    order = np.argsort(-sims)[:k]
    return [(STORE["chunks"][i], float(sims[i])) for i in order]


class Ask(BaseModel):
    q: str
    k: int = 4


@app.get("/health")
def health():
    return {"status": "ok" if STORE["matrix"] is not None else "ingesting",
            "chunks": len(STORE["chunks"]), "dim": STORE["dim"]}


@app.get("/store")
def store():
    return {"chunks": len(STORE["chunks"]), "dim": STORE["dim"],
            "pdf_source": STORE["pdf_source"],
            "items": [{"id": c["id"], "title": c["title"], "source": c["source"],
                       "preview": c["text"][:120]} for c in STORE["chunks"]]}


@app.post("/ask")
def ask(a: Ask):
    hits = retrieve(a.q, a.k)
    context = "\n\n".join(f"[{c['id']}] {c['title']}\n{c['text']}" for c, _ in hits)
    from openai import OpenAI

    client = OpenAI(base_url=os.environ["OPENAI_API_BASE"], api_key=os.environ["OPENAI_API_KEY"])
    sys = ("You are the Parasol policy assistant. Answer the question using ONLY the policy "
           "passages provided. Cite the passage id(s) you used, e.g. [POL-AUTO-01]. If the "
           "passages do not contain the answer, say you don't have that policy information.")
    msg = client.chat.completions.create(
        model=MAAS_MODEL, temperature=0,
        messages=[{"role": "system", "content": sys},
                  {"role": "user", "content": f"Policy passages:\n{context}\n\nQuestion: {a.q}"}],
    )
    return JSONResponse({
        "question": a.q,
        "answer": msg.choices[0].message.content,
        "sources": [{"id": c["id"], "title": c["title"], "source": c["source"],
                     "score": round(s, 3)} for c, s in hits],
    })


SUGGESTIONS = [
    "What is the standard deductible for an auto collision claim, and how long is rental-car reimbursement included?",
    "What is the policy term for a Parasol auto policy, and is renewal automatic?",
    "How many business days does Parasol target for first adjuster contact and a standard decision?",
    "Is flood damage covered by the base Parasol home policy?",
]


@app.get("/", response_class=HTMLResponse)
def index():
    sug = "".join(f'<button class="s" onclick="ask(this.textContent)">{q}</button>' for q in SUGGESTIONS)
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Parasol Policy RAG</title>
<style>
 body{{font-family:system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}}
 h1{{font-size:1.4rem}} .sub{{color:#666;margin-top:-.6rem}}
 input{{width:100%;padding:.7rem;font-size:1rem;box-sizing:border-box;border:1px solid #ccc;border-radius:6px}}
 button.go{{margin-top:.6rem;padding:.6rem 1.2rem;font-size:1rem;background:#c00;color:#fff;border:0;border-radius:6px;cursor:pointer}}
 .s{{display:block;width:100%;text-align:left;margin:.3rem 0;padding:.5rem;background:#f4f4f4;border:1px solid #e0e0e0;border-radius:6px;cursor:pointer;font-size:.9rem}}
 #ans{{white-space:pre-wrap;background:#f7f7f9;border-left:4px solid #c00;padding:1rem;border-radius:4px;margin-top:1rem;min-height:1rem}}
 .src{{font-size:.85rem;color:#444;margin-top:.8rem}} .src b{{color:#c00}}
 .tag{{display:inline-block;background:#eee;border-radius:4px;padding:.1rem .4rem;margin:.1rem;font-size:.8rem}}
</style></head><body>
<h1>Parasol Policy Assistant — RAG</h1>
<p class=sub>Docling-ingested policy docs + nomic-embed-text vector retrieval, answered by llama-scout.</p>
<input id=q placeholder="Ask a policy question..." onkeydown="if(event.key==='Enter')ask(q.value)">
<button class=go onclick="ask(q.value)">Ask</button>
<div style="margin-top:1rem"><b>Try:</b>{sug}</div>
<div id=ans></div><div id=src class=src></div>
<script>
async function ask(t){{
  document.getElementById('q').value=t;
  document.getElementById('ans').textContent='Retrieving + answering...';
  document.getElementById('src').innerHTML='';
  const r=await fetch('/ask',{{method:'POST',headers:{{'content-type':'application/json'}},body:JSON.stringify({{q:t}})}});
  const d=await r.json();
  document.getElementById('ans').textContent=d.answer;
  document.getElementById('src').innerHTML='<b>Retrieved passages:</b> '+d.sources.map(s=>'<span class=tag>'+s.id+' ('+s.score+')</span>').join('');
}}
</script></body></html>"""
