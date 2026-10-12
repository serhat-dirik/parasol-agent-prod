"""python3 kb/test_kb.py : the corpus, the chunking and what a caller is told about withheld passages."""
import json
import os

os.environ.setdefault("KB_ENFORCE", "false")
from common import AUDIENCE, chunks, load_docs  # noqa: E402
from server import Caller, answer, verify  # noqa: E402

docs = load_docs()
assert len(docs) >= 10 and len({d["id"] for d in docs}) == len(docs)
for d in docs:
    restricted = d["classification"] == "restricted"
    assert ("CONFIDENTIAL — Claims managers only" in d["body"]) == restricted, d["id"]
    assert all(len(c) < 1400 for c in chunks(d)), d["id"]
assert "contractors" in AUDIENCE["public"] and "contractors" not in AUDIENCE["internal"]
assert AUDIENCE["restricted"] == ["claims-managers"]

# withheld passages: a count and a label for the caller, never a doc id, title or content
out = answer([("PUB-01", "How to file", "public", "text", 0.8)], [("RST-01", "restricted"), ("RST-01", "restricted")])
s = json.dumps(out)
assert out["withheld"] == {"count": 2, "classifications": {"restricted": 2}} and "RST-01" not in s

assert Caller(groups=["/claims-managers", "adjusters"]).groups == ["adjusters", "claims-managers"]
for bad in (None, "", "Basic x"):
    try:
        verify(bad)
        raise AssertionError("accepted " + repr(bad))
    except ValueError:
        pass
print("ok")
