#!/usr/bin/env bash
# Sourced by the Keycloak admin-API scripts: sets KC_USER / KC_PASS for the master realm admin.
# Order: KEYCLOAK_ADMIN_USER/KEYCLOAK_ADMIN_PASSWORD env, then the lab credentials file (a lab-provided
# Keycloak), then Secret keycloak/keycloak-initial-admin (the instance gitops/platform/keycloak-instance
# creates). Values are never printed.
KC_USER="${KEYCLOAK_ADMIN_USER:-}" KC_PASS="${KEYCLOAK_ADMIN_PASSWORD:-}"
_cred_file="${CREDENTIALS_FILE:-$(dirname "${BASH_SOURCE[0]}")/../../credentials.txt}"
if [ -z "$KC_USER" ] && [ -r "$_cred_file" ]; then
  KC_USER="$(awk '$0=="keycloak_admin_user" {getline; print; exit}' "$_cred_file")"
  KC_PASS="$(awk '$0=="keycloak_admin_password" {getline; print; exit}' "$_cred_file")"
fi
if [ -z "$KC_USER" ] && oc get secret keycloak-initial-admin -n keycloak >/dev/null 2>&1; then
  KC_USER="$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d)"
  KC_PASS="$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)"
fi
[ -n "$KC_USER" ] && [ -n "$KC_PASS" ] || { echo "no Keycloak admin login: set KEYCLOAK_ADMIN_USER/KEYCLOAK_ADMIN_PASSWORD" >&2; exit 1; }
unset _cred_file
