#!/usr/bin/env python3
"""Detect-or-install every operator in a Subscription stream, then wait for all of them.

  kustomize build gitops/bootstrap/operators | scripts/ensure-operators.py

Per package it prints "already installed" (a Subscription or an OLM-installed CSV for that package in ANY
namespace, so an operator the lab shipped is reused) or "installing" (Namespace if missing, OperatorGroup
only when the namespace has none -- a second OperatorGroup breaks OLM for the namespace -- and the
Subscription). A Subscription with installPlanApproval Manual + startingCSV gets exactly that InstallPlan
approved (pins a version). Then it polls every 30 s, printing each CSV phase, until all are Succeeded.
Deadline 20 min (expected 2-10 min + 50 %). Exit 1 on a Failed CSV or the deadline, naming the package.
Env: RHOAI_CHANNEL / RHOAI_CSV override the rhods-operator channel / startingCSV (RHOAI_CSV= empty -> Automatic, latest).
"""
import json, os, subprocess, sys, time
import yaml

DEADLINE_S = int(os.environ.get("OPERATOR_DEADLINE_S", "1200"))


def oc(*args, stdin=None, check=True):
    r = subprocess.run(["oc", *args], input=stdin, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"oc {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def items(kind):
    out = oc("get", kind, "-A", "-o", "json", check=False)
    return json.loads(out)["items"] if out.strip() else []


def apply(doc):
    oc("apply", "-f", "-", stdin=yaml.safe_dump(doc))


def main():
    docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
    subs_wanted = [d for d in docs if d["kind"] == "Subscription"]
    for s in subs_wanted:  # version pin overrides for OpenShift AI
        if s["spec"]["name"] == "rhods-operator":
            if os.environ.get("RHOAI_CHANNEL"):
                s["spec"]["channel"] = os.environ["RHOAI_CHANNEL"]
            if "RHOAI_CSV" in os.environ:
                if os.environ["RHOAI_CSV"]:
                    s["spec"]["startingCSV"] = os.environ["RHOAI_CSV"]
                else:
                    s["spec"].pop("startingCSV", None)
                    s["spec"]["installPlanApproval"] = "Automatic"
    by_ns = lambda kind: {d["metadata"]["namespace"] for d in items(kind)}  # noqa: E731
    subs = items("subscriptions.operators.coreos.com")
    csvs = [c for c in items("clusterserviceversions.operators.coreos.com")
            if "olm.copiedFrom" not in c["metadata"].get("labels", {})]
    og_ns = by_ns("operatorgroups.operators.coreos.com")
    namespaces = set(oc("get", "ns", "-o", "jsonpath={.items[*].metadata.name}").split())

    watch = {}  # pkg -> (namespace, wanted subscription or None)
    for want in subs_wanted:
        pkg, ns = want["spec"]["name"], want["metadata"]["namespace"]
        have = next((s for s in subs if s["spec"]["name"] == pkg), None)
        if have:
            hns = have["metadata"]["namespace"]
            print(f"already installed: {pkg} (Subscription in {hns}, {have.get('status', {}).get('installedCSV', 'installing')})")
            watch[pkg] = (hns, have)
            continue
        csv = next((c for c in csvs if any(k.startswith(f"operators.coreos.com/{pkg}.")
                                           for k in c["metadata"].get("labels", {}))), None)
        if csv:
            print(f"already installed: {pkg} (CSV {csv['metadata']['name']} in {csv['metadata']['namespace']}, no Subscription)")
            continue
        print(f"installing: {pkg} (channel {want['spec']['channel']}, namespace {ns})")
        if ns not in namespaces:
            apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}})
            namespaces.add(ns)
        if ns != "openshift-operators":
            if ns in og_ns:
                print(f"  OperatorGroup already present in {ns}: not adding another")
            else:
                og = next((d for d in docs if d["kind"] == "OperatorGroup" and d["metadata"]["namespace"] == ns), None)
                if og:
                    apply(og)
                    og_ns.add(ns)
        apply(want)
        watch[pkg] = (ns, want)

    start, done, failed = time.time(), set(), {}
    while True:
        line = []
        for pkg, (ns, want) in watch.items():
            if pkg in done or pkg in failed:
                continue
            sub = json.loads(oc("get", "subscriptions.operators.coreos.com", "-n", ns, "-o", "json"))["items"]
            sub = next((s for s in sub if s["spec"]["name"] == pkg), {})
            spec, st = sub.get("spec", {}), sub.get("status", {})
            if spec.get("installPlanApproval") == "Manual" and spec.get("startingCSV"):
                for ip in json.loads(oc("get", "installplans.operators.coreos.com", "-n", ns, "-o", "json"))["items"]:
                    if (not ip["spec"].get("approved") and
                            spec["startingCSV"] in ip["spec"].get("clusterServiceVersionNames", [])):
                        oc("patch", "installplan", ip["metadata"]["name"], "-n", ns, "--type", "merge",
                           "-p", '{"spec":{"approved":true}}')
                        print(f"  approved InstallPlan {ip['metadata']['name']} for {spec['startingCSV']}")
            name = st.get("installedCSV") or st.get("currentCSV")
            phase = "no CSV yet"
            if name:
                phase = oc("get", "csv", name, "-n", ns, "-o", "jsonpath={.status.phase}", check=False) or "pending"
            if phase == "Succeeded":
                done.add(pkg)
            elif phase == "Failed":
                failed[pkg] = oc("get", "csv", name, "-n", ns, "-o", "jsonpath={.status.message}", check=False)
            line.append(f"{pkg}={phase}")
        if len(done) + len(failed) == len(watch):
            break
        if time.time() - start > DEADLINE_S:
            for pkg in watch:
                if pkg not in done and pkg not in failed:
                    failed[pkg] = "deadline exceeded"
            break
        print(time.strftime("%H:%M:%S"), " ".join(line), flush=True)
        time.sleep(30)
    for pkg, why in failed.items():
        print(f"FAILED: {pkg}: {why}  (oc get csv,subscription,installplan -n {watch[pkg][0]})")
    print(f"operators ready: {len(done)}/{len(watch)} watched")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
