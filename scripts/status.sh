#!/usr/bin/env bash
# One screen of install state: every component bootstrap.sh wires. Read-only.
D=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null)
sec(){ printf '\n--- %s\n' "$1"; }
sec "operators (CSV phase)"
oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.status.installedCSV}{"\n"}{end}' 2>/dev/null \
  | while read -r ns csv; do [ -n "$csv" ] && printf '  %-45s %s\n' "$csv" "$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)"; done
sec "Argo applications"
oc get applications -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null
sec "OpenShift AI"
oc get datasciencecluster -o jsonpath='{range .items[0].status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null | grep -E 'Ready=' | sed 's/^/  /'
oc get modelregistry -n rhoai-model-registries 2>/dev/null; oc get mlflow -A 2>/dev/null; oc get evalhub,lmevaljob -n parasol-eval 2>/dev/null
oc get ogxserver -n parasol-ogx-playground 2>/dev/null; oc get externalmodel,maassubscription -n models-as-a-service 2>/dev/null
sec "gateway and identity"
oc get gateway -A 2>/dev/null; oc get mcpserverregistration -A 2>/dev/null; oc get authpolicy -A 2>/dev/null
oc get keycloak,keycloakrealmimport -n keycloak 2>/dev/null
sec "supply chain"
oc get securesign -n trusted-artifact-signer 2>/dev/null; oc get zerotrustworkloadidentitymanager 2>/dev/null
oc get clusterimagepolicy,trustroot 2>/dev/null
echo "parasol-secured admission label: $(oc get ns parasol-secured -o jsonpath='{.metadata.labels.policy\.rhtas\.com/include}' 2>/dev/null)"
oc get pipelinerun -n parasol-build -o custom-columns=RUN:.metadata.name,STATUS:.status.conditions[0].reason 2>/dev/null
echo "gitops-auth-secret (promote token): $(oc get secret gitops-auth-secret -n parasol-build -o name 2>/dev/null || echo MISSING)"
sec "pods"
for ns in keycloak parasol-free parasol-secured; do echo "[$ns]"; oc get pods -n $ns 2>/dev/null; done
echo "secured portal image: $(oc get deploy portal -n parasol-secured -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
sec "URLs"
echo "portal unsecured: https://portal-free.apps.$D"
echo "portal secured:   https://portal.apps.$D"
echo "keycloak:         https://sso.apps.$D"
echo "mcp gateway:      https://mcp.apps.$D/mcp"
echo "showroom:         https://showroom-parasol-showroom.apps.$D"
