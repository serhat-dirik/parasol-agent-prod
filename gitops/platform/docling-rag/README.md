# V6 — Docling + nomic-embed policy RAG (isolated)

Policy-document RAG for the Parasol assistant, built as an **additive, isolated** stream
in namespace `parasol-rag`. It does **not** touch the shared DataScienceCluster / KServe,
the portal, or any wave-1 state.

## What it is

- **nomic-embed-text served on CPU** — `nomic-ai/nomic-embed-text-v1.5` via
  sentence-transformers behind a tiny FastAPI `/embed` endpoint (`embed-server.yaml`).
  768-dim, normalized, v1.5 task prefixes (`search_document:` / `search_query:`).
- **Docling ingestion** — `policy-rag` parses the Parasol policy PDF
  (`apps/parasol-portal/.../policy-info.pdf`) with Docling into Markdown, chunks it, and
  also ingests the 8-doc seeded policy corpus (`app/corpus.json`).
- **Vector store** — every chunk is embedded via the nomic endpoint and kept in an
  in-memory numpy cosine store (`ponytail:` tiny fixed corpus; swap in pgvector/Milvus
  when it outgrows memory). `GET /store` shows the populated store.
- **RAG answer** — `POST /ask` embeds the question, retrieves the nearest chunks, and
  asks `llama-scout-17b` (MaaS, key 2) to answer grounded only in those chunks, citing
  passage ids. Browser UI at the Route root.

## Deploy / re-deploy

```sh
bash scripts/docling-rag.sh        # idempotent; reads MaaS key 2 at run time (never committed)
oc get pods -n parasol-rag
oc get route policy-rag -n parasol-rag -o jsonpath='{.spec.host}'
```

## Verify

```sh
HOST=$(oc get route policy-rag -n parasol-rag -o jsonpath='{.spec.host}')
curl -sk "https://$HOST/store" | head       # vector store populated: N chunks, dim=768
curl -sk "https://$HOST/ask" -H 'content-type: application/json' \
  -d '{"q":"What is the standard deductible for an auto collision claim?"}'
```

Browser: open `https://$HOST/`, click a suggested question — grounded answer + the
retrieved passage ids (e.g. `[POL-AUTO-01]`).

## Notes

- Not Argo-wired (applied with `scripts/docling-rag.sh`), matching the other wave-2
  isolated streams (S1–S4).
- `POL-VENDOR-07` is ingested with its legitimate windshield-network text only; the
  hidden "processing note" injection payload (demonstrated by other streams) is omitted
  from this corpus, and the RAG app has no tools wired, so no payout tool can be called.
- Teardown: `oc delete ns parasol-rag`.
