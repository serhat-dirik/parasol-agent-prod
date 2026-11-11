#!/usr/bin/env python3
"""Run the release gate as a TrustyAI EvalHub job (provider parasol-agent-gate, benchmark golden-set), wait for
it, and write the same results directory agent_eval.py --results-dir writes (gate, score, run-id, run-url,
gate-reason, model-only-passed, prompt-sha256, released-prompt/), so the Tekton task agent-eval-evalhub hands
the pipeline the same results as agent-eval. Standard library only (runs in ubi9/python-311 and on a laptop).

Per job it creates a credentials Secret in parasol-eval (the job's model.auth.secret_ref): api-key = the eval's
agent MaaS key, hf-token = JSON with the agent and judge endpoints/models/keys (parasol-build/maas-eval-agent-key
and maas-eval-key) and a token of ServiceAccount parasol-eval/parasol-agent-gate valid for the job's deadline.
The Secret is deleted when the job ends. See evalhub_adapter.py for why the credentials travel this way.

In-cluster defaults: EvalHub https://parasol-evalhub.parasol-eval.svc:8443, Kubernetes API from the pod, the
pod's ServiceAccount token. From a laptop: EVALHUB_URL=https://localhost:18443 (oc port-forward), KUBE_API from
`oc whoami --show-server`, TOKEN=$(oc whoami -t), INSECURE=1.
Exit 0 when the job completed (gate passed or failed: read <results-dir>/gate), 1 when it failed or timed out.
"""
import argparse, base64, hashlib, json, os, pathlib, ssl, sys, time, urllib.error, urllib.request

NS, PROVIDER, BENCHMARK, SA = "parasol-eval", "parasol-agent-gate", "golden-set", "parasol-agent-gate"
SA_DIR = pathlib.Path("/var/run/secrets/kubernetes.io/serviceaccount")


class Api:
    def __init__(self):
        self.kube = os.environ.get("KUBE_API", "https://kubernetes.default.svc").rstrip("/")
        self.hub = os.environ.get("EVALHUB_URL", f"https://parasol-evalhub.{NS}.svc:8443").rstrip("/")
        tok = os.environ.get("TOKEN") or (SA_DIR / "token").read_text().strip()
        self.h = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}
        if os.environ.get("INSECURE") == "1":
            self.kctx = self.hctx = ssl._create_unverified_context()
        else:
            self.kctx = ssl.create_default_context(cafile=str(SA_DIR / "ca.crt"))
            self.hctx = ssl.create_default_context(cafile=str(SA_DIR / "service-ca.crt"))

    def call(self, method, url, body=None, ctx=None, headers=None):
        req = urllib.request.Request(url, json.dumps(body).encode() if body is not None else None,
                                     {**self.h, **(headers or {})}, method=method)
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {url}: HTTP {e.code} {e.read()[:300]!r}") from None

    def k(self, method, path, body=None):
        return self.call(method, self.kube + path, body, self.kctx)

    def e(self, method, path, body=None):
        return self.call(method, self.hub + "/api/v1/evaluations" + path, body, self.hctx, {"X-Tenant": NS})


def secret(api, ns, name):
    d = api.k("GET", f"/api/v1/namespaces/{ns}/secrets/{name}")["data"]
    return {k: base64.b64decode(v).decode().strip() for k, v in d.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", default="production")
    ap.add_argument("--prompt-ref", default="")
    ap.add_argument("--prompt-file", required=True, help="the prompt text the release ships")
    ap.add_argument("--prompt-file-rel", default="", help="its path in the repository")
    ap.add_argument("--eval-path", default=str(pathlib.Path(__file__).resolve().parent),
                    help="directory with golden-set.json and fixtures.json (the release revision)")
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--attempts", default="3")
    ap.add_argument("--release-run", default="")
    ap.add_argument("--cases", default="", help="comma-separated case ids (subset run); default all")
    ap.add_argument("--mlflow-uri", default="https://mlflow.redhat-ods-applications.svc:8443/mlflow")
    ap.add_argument("--mlflow-workspace", default="parasol-secured")
    ap.add_argument("--experiment", default="parasol-agent-eval")
    ap.add_argument("--baseline-experiment", default="")
    ap.add_argument("--eval-kind", default="")
    ap.add_argument("--timeout-min", type=int, default=50)
    a = ap.parse_args()
    api = Api()
    run = a.release_run or time.strftime("manual-%Y%m%d-%H%M%S")

    prov = [p for p in api.e("GET", f"/providers?name={PROVIDER}&limit=50").get("items", []) if p["name"] == PROVIDER]
    if not prov:
        sys.exit(f"provider {PROVIDER} is not registered in EvalHub (scripts/evalhub-gate.sh)")
    prompt = pathlib.Path(a.prompt_file).read_text()
    ev = pathlib.Path(a.eval_path)
    params = {"candidate": a.candidate, "prompt_text": prompt, "prompt_file_rel": a.prompt_file_rel,
              "prompt_ref": a.prompt_ref, "attempts": int(a.attempts), "release_run": run,
              "golden_set": (ev / "golden-set.json").read_text(), "fixtures": (ev / "fixtures.json").read_text(),
              "mlflow_uri": a.mlflow_uri, "mlflow_workspace": a.mlflow_workspace, "experiment": a.experiment}
    for k, v in (("cases", [c for c in a.cases.split(",") if c]), ("baseline_experiment", a.baseline_experiment),
                 ("eval_kind", a.eval_kind)):
        if v:
            params[k] = v

    agent = secret(api, "parasol-build", "maas-eval-agent-key")
    try:
        judge = secret(api, "parasol-build", "maas-eval-key")
    except RuntimeError:
        judge = {}
        print("maas-eval-key not readable: the job runs the deterministic-only gate (no judge calls)")
    tok = api.k("POST", f"/api/v1/namespaces/{NS}/serviceaccounts/{SA}/token",
                {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenRequest",
                 "spec": {"expirationSeconds": (a.timeout_min + 15) * 60}})["status"]["token"]
    creds = {"agent_endpoint": agent["endpoint"], "agent_model": agent["model"], "agent_key": agent["key"],
             "judge_endpoint": judge.get("endpoint", ""), "judge_model": judge.get("model", ""),
             "judge_key": judge.get("key", ""), "token": tok}
    sname = "agent-gate-" + hashlib.sha256(run.encode()).hexdigest()[:10]
    api.k("POST", f"/api/v1/namespaces/{NS}/secrets",
          {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": sname, "labels": {"app": "parasol-agent-gate"}},
           "stringData": {"api-key": agent["key"], "hf-token": json.dumps(creds)}})
    del creds, tok
    try:
        job = api.e("POST", "/jobs", {
            "name": f"parasol-agent-gate {a.candidate} {run}",
            "description": f"Release gate: golden set ({len(params.get('cases', [])) or 'all'} cases), agent version "
                           f"{a.candidate}, prompt {a.prompt_ref or a.prompt_file_rel or 'unregistered'}",
            "tags": ["parasol", "release-gate", a.candidate],
            "model": {"url": agent["endpoint"], "name": agent["model"], "auth": {"secret_ref": sname}},
            "benchmarks": [{"id": BENCHMARK, "provider_id": prov[0]["resource"]["id"], "parameters": params,
                            "primary_score": {"metric": "gate_passed", "lower_is_better": False},
                            "pass_criteria": {"threshold": 1.0}}],
            "pass_criteria": {"threshold": 1.0}})
        jid = job["resource"]["id"]
        print(f"EvalHub job {jid} submitted ({a.candidate}, run {run})", flush=True)
        deadline, state = time.time() + a.timeout_min * 60, ""
        while time.time() < deadline:
            job = api.e("GET", f"/jobs/{jid}")
            state = job["status"]["state"]
            b = (job["status"].get("benchmarks") or [{}])[0]
            print(f"{time.strftime('%H:%M:%S')} {state} {b.get('phase', '')}", flush=True)
            if state in ("completed", "failed", "cancelled", "partially_failed"):
                break
            time.sleep(20)
    finally:
        try:
            api.k("DELETE", f"/api/v1/namespaces/{NS}/secrets/{sname}")
        except RuntimeError as e:
            print(f"WARN: could not delete Secret {NS}/{sname}: {e}")
    if state != "completed":
        print(f"EvalHub job {jid} ended {state or 'without a terminal state (timeout)'}: "
              f"{json.dumps(job['status'].get('message') or job['status'])[:600]}")
        return 1
    res = job.get("results") or {}
    info = (res.get("benchmarks") or [{}])[0].get("additional_info") or {}
    if not info.get("gate"):
        print(f"EvalHub job {jid} completed without a gate result: {json.dumps(res)[:600]}")
        return 1
    rd = pathlib.Path(a.results_dir)
    rd.mkdir(parents=True, exist_ok=True)
    for f, k in (("gate", "gate"), ("score", "score"), ("run-id", "mlflow_run_id"), ("run-url", "mlflow_run_url"),
                 ("gate-reason", "gate_reason"), ("model-only-passed", "model_only_passed")):
        (rd / f).write_text(info.get(k, ""))
    if a.prompt_ref:   # as agent_eval.release_prompt: the released text, its registry version and sha256
        (rd / "prompt-sha256").write_text(info.get("prompt_sha256", ""))
        rp = rd / "released-prompt"
        rp.mkdir(exist_ok=True)
        (rp / "systemPrompt").write_text(prompt)
        (rp / "promptVersion").write_text(info.get("prompt_version", ""))
        (rp / "promptSha256").write_text(info.get("released_prompt_sha256", ""))
    print(f"EvalHub job {jid}: gate={info['gate']} score={info['score']} test={json.dumps(res.get('test'))} "
          f"mlflow-run-id={info.get('mlflow_run_id')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
