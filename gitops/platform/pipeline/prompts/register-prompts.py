#!/usr/bin/env python3
"""Register the Parasol claims-assistant system prompt (v1 + v2) in the MLflow
Prompt Registry, in the parasol-secured workspace. Idempotent: re-running creates
new versions only if the template text changed (MLflow dedupes identical content).

Runs in-cluster. Auth: the pod's own ServiceAccount token (must have the
mlflow-operator-mlflow-edit ClusterRole bound in namespace parasol-secured).
Workspace routing: the x-mlflow-workspace request header (= namespace)."""
import os, sys, pathlib, mlflow
from mlflow.tracking.request_header.abstract_request_header_provider import (
    RequestHeaderProvider,
)

WORKSPACE = os.environ.get("MLFLOW_WORKSPACE", "parasol-secured")
PROMPT = os.environ.get("PROMPT_NAME", "parasol-claims-assistant-system-prompt")
HERE = pathlib.Path(__file__).parent


class WorkspaceHeader(RequestHeaderProvider):
    def in_context(self):
        return True

    def request_headers(self):
        return {"x-mlflow-workspace": WORKSPACE}


# register the workspace header on every MLflow REST call
try:
    from mlflow.tracking.request_header.registry import _request_header_provider_registry
    _request_header_provider_registry.register(WorkspaceHeader)
except Exception as e:  # pragma: no cover - API name drift guard
    print(f"header-provider registration failed: {e}", file=sys.stderr)
    raise

# bearer token = the pod SA token
tok_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
if os.path.exists(tok_path):
    os.environ["MLFLOW_TRACKING_TOKEN"] = pathlib.Path(tok_path).read_text().strip()
os.environ.setdefault("MLFLOW_TRACKING_INSECURE_TLS", "true")

common = {
    "agent": "parasol-claims-assistant",
    "source_file": "apps/parasol-portal/app/src/main/java/org/parasol/ai/ClaimsAssistant.java",
    "tools_authpolicy_path": "gitops/platform/mcp-gateway/authpolicy-tools.yaml",
    "tools_authpolicy_sha256": "02619907984be688d238cb2510610458018e427c56066b4e8335bc2b33a1310e",
    "model_id": "llama-scout-17b",
    "model_config_name": "parasol-chat",
}
versions = [
    {
        "file": "v1.txt",
        "commit": "v1: current secured prompt (base + 3 safety rules). Passes 20/20.",
        "tags": {**common, "variant": "v1-secured",
                 "safety_rules_file": "gitops/envs/secured/safety-rules.txt",
                 "expected_golden_pass": "20/20"},
    },
    {
        "file": "v2.txt",
        "commit": "v2: simplified prompt, safety-rules block removed. Fails 3/20 -> 17/20, blocked by the 19/20 gate.",
        "tags": {**common, "variant": "v2-simplified",
                 "safety_rules_file": "none",
                 "expected_golden_pass": "17/20"},
    },
]

CANDIDATE_URIS = [
    os.environ.get("MLFLOW_TRACKING_URI"),
    "https://mlflow.redhat-ods-applications.svc:8443",
    "https://mlflow.redhat-ods-applications.svc:8443/mlflow",
]


def pick_uri():
    for uri in [u for u in CANDIDATE_URIS if u]:
        try:
            mlflow.set_tracking_uri(uri)
            mlflow.set_registry_uri(uri)
            mlflow.search_experiments(max_results=1)
            print(f"tracking uri OK: {uri}")
            return uri
        except Exception as e:
            print(f"tracking uri {uri} -> {type(e).__name__}: {str(e)[:160]}")
    raise SystemExit("no working MLflow tracking URI")


def register_fn():
    for name in ("register_prompt",):
        fn = getattr(mlflow, name, None)
        if fn:
            return fn
    import mlflow.genai as g  # mlflow 3.x
    return g.register_prompt


def cleanup():
    """Drop the prompt so v1/v2 numbering is deterministic. Best-effort."""
    from mlflow import MlflowClient
    c = MlflowClient()
    for attempt in (
        lambda: __import__("mlflow").delete_prompt(PROMPT),
        lambda: c.delete_prompt(PROMPT),
        lambda: c.delete_registered_model(PROMPT),
    ):
        try:
            attempt()
            print(f"cleanup: deleted existing prompt {PROMPT}")
            return
        except Exception as e:
            last = e
    print(f"cleanup: nothing to delete or not supported ({type(last).__name__})")


def main():
    pick_uri()
    if os.environ.get("RESET") == "1":
        cleanup()
    reg = register_fn()
    for v in versions:
        template = (HERE / v["file"]).read_text()
        pv = reg(name=PROMPT, template=template,
                 commit_message=v["commit"], tags=v["tags"])
        print(f"registered {PROMPT} v{pv.version} <- {v['file']} "
              f"(variant={v['tags']['variant']})")
    # read back
    for ver in (1, 2):
        try:
            p = mlflow.load_prompt(f"prompts:/{PROMPT}/{ver}")
            print(f"loaded {PROMPT}/{ver}: {len(p.template)} chars, "
                  f"variant={p.tags.get('variant')}")
        except Exception as e:
            print(f"load {PROMPT}/{ver} failed: {e}")


if __name__ == "__main__":
    main()
