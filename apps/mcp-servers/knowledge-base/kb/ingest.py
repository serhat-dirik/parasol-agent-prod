"""Ingestion job: schema, roles, row-level security, then embed + replace every chunk. Idempotent.

Runs as the PostgreSQL superuser (only it may create the vector extension and the app role). The table
and the withheld-count function belong to kb_owner; the server logs in as kb_app, which is neither owner
nor superuser, so the row-level security policy applies to every query it makes.
KB_SECURED=true  : RLS on - kb_app sees only rows whose audience overlaps the groups the server sets per
                   transaction (set_config('kb.groups', ...)); nothing when they are not set.
KB_SECURED=false : RLS off (the uncontrolled baseline of parasol-free).
"""
import os

import psycopg
from psycopg import sql

from common import AUDIENCE, DIM, chunks, embed, load_docs, vec

SECURED = os.environ.get("KB_SECURED", "false").lower() == "true"

SCHEMA = f"""
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS chunks (
  id             text PRIMARY KEY,
  doc_id         text NOT NULL,
  title          text NOT NULL,
  classification text NOT NULL,
  audience       text[] NOT NULL,
  content        text NOT NULL,
  embedding      vector({DIM}) NOT NULL
);
ALTER TABLE chunks OWNER TO kb_owner;
-- Counts what the caller may NOT read among the best matches: labels and doc ids for the server's audit
-- log only (the server returns count + classification to the caller, never ids, titles or content).
-- SECURITY DEFINER as the table owner, which RLS does not apply to (no FORCE).
DROP FUNCTION IF EXISTS kb_withheld(vector, text[], int, float);
CREATE FUNCTION kb_withheld(q vector, groups text[], k int, min_score float)
RETURNS TABLE(doc_id text, classification text, score float)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.doc_id, c.classification, 1 - c.d FROM (
    SELECT doc_id, classification, audience, embedding <=> q AS d FROM chunks ORDER BY embedding <=> q LIMIT k
  ) c WHERE NOT (c.audience && groups) AND 1 - c.d >= min_score
$$;
ALTER FUNCTION kb_withheld(vector, text[], int, float) OWNER TO kb_owner;
REVOKE ALL ON FUNCTION kb_withheld(vector, text[], int, float) FROM PUBLIC;
GRANT SELECT ON chunks TO kb_app;
DROP POLICY IF EXISTS chunks_by_group ON chunks;
"""

RLS_ON = """
ALTER TABLE chunks ENABLE ROW LEVEL SECURITY;
CREATE POLICY chunks_by_group ON chunks FOR SELECT TO kb_app
  USING (audience && string_to_array(nullif(current_setting('kb.groups', true), ''), ','));
GRANT EXECUTE ON FUNCTION kb_withheld(vector, text[], int, float) TO kb_app;
"""
RLS_OFF = "ALTER TABLE chunks DISABLE ROW LEVEL SECURITY;"


def main():
    rows = []
    for d in load_docs():
        for i, text in enumerate(chunks(d)):
            rows.append((f"{d['id']}#{i}", d["id"], d["title"], d["classification"],
                         AUDIENCE[d["classification"]], text))
    vectors = embed([f"{r[2]}\n\n{r[5]}" for r in rows])
    dsn = os.environ["KB_ADMIN_DSN"]
    with psycopg.connect(dsn, autocommit=True) as conn:
        for role, pw in (("kb_owner", None), ("kb_app", os.environ["KB_APP_PASSWORD"])):
            if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", [role]).fetchone():
                conn.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role)))
            if pw:   # login, never superuser, never BYPASSRLS
                conn.execute(sql.SQL("ALTER ROLE {} LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD {}")
                             .format(sql.Identifier(role), sql.Literal(pw)))
        with conn.transaction():
            conn.execute(SCHEMA)
            conn.execute(RLS_ON if SECURED else RLS_OFF)
            conn.execute("DELETE FROM chunks")
            with conn.cursor() as cur:
                cur.executemany("INSERT INTO chunks VALUES (%s,%s,%s,%s,%s,%s,%s::vector)",
                                [r + (vec(v),) for r, v in zip(rows, vectors)])
    by = {}
    for r in rows:
        by[r[3]] = by.get(r[3], 0) + 1
    print(f"ingested {len(rows)} chunks from {len({r[1] for r in rows})} documents {by} rls={'on' if SECURED else 'off'}",
          flush=True)


if __name__ == "__main__":
    main()
