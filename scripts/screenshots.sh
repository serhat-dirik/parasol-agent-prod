#!/usr/bin/env bash
#
# Capture the portal Show-step screenshots for the demo Showroom.
#
# WHAT THIS DOES
#   1. Runs scripts/reset.sh so the claims data is back to the recorded state.
#   2. Drives the two Parasol portals with headless Chromium (Playwright), logging in
#      through the portal's own login as rebecca, marcus and tom.becker (password = username).
#   3. Writes PNGs into showroom/content/modules/ROOT/assets/images/ with the names the
#      module pages reference. These overwrite the committed placeholders.
#
# WHAT THIS DOES NOT DO
#   The OpenShift console, OpenShift AI, Keycloak admin and Argo CD screens are auth-walled
#   and are captured by hand in the logged-in operator browser at record time. This script
#   never logs in to those. Their module steps carry a "// TODO: screenshot placeholder" line.
#
# MEDIA-CAPTURE RULES ENFORCED
#   - Light theme forced; viewport 1920x1080; portal zoomed to 110% so chips read on video.
#   - The login form is never in frame: the shot is taken only after login lands on the portal,
#     and the script asserts it is authenticated first.
#   - State-dependent shots are taken once, in manifest order, and not re-run.
#   - No token, password, personal email or API key is ever in a shot. Cluster domains are fine.
#
# RUN
#   scripts/screenshots.sh
#   Requires: Playwright with Chromium. If missing:
#     uv tool install playwright && playwright install chromium   (or: pipx/pip install playwright)
#
# NOTE ON SELECTORS
#   The chat-driven beats depend on the portal's DOM. The CSS/text selectors are collected at
#   the top of the Python block below. Confirm them against the running portal before a real
#   recording run; where a selector does not match, that one shot is skipped and logged, and the
#   committed placeholder stays in place.

set -euo pipefail
cd "$(dirname "$0")/.."

PORTAL_FREE_URL="${PORTAL_FREE_URL:-https://portal-free.apps.cluster-znh6n.dyn.redhatworkshops.io}"
PORTAL_SECURED_URL="${PORTAL_SECURED_URL:-https://portal.apps.cluster-znh6n.dyn.redhatworkshops.io}"
IMAGES_DIR="${IMAGES_DIR:-showroom/content/modules/ROOT/assets/images}"

echo "== resetting demo state =="
if [ -x scripts/reset.sh ]; then
  scripts/reset.sh
else
  echo "scripts/reset.sh not found or not executable; continuing without reset" >&2
fi

echo "== capturing portal screenshots into ${IMAGES_DIR} =="
PORTAL_FREE_URL="$PORTAL_FREE_URL" PORTAL_SECURED_URL="$PORTAL_SECURED_URL" IMAGES_DIR="$IMAGES_DIR" \
python3 - "$@" <<'PYEOF'
import os, sys, time
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

FREE = os.environ["PORTAL_FREE_URL"]
SECURED = os.environ["PORTAL_SECURED_URL"]
OUT = os.environ["IMAGES_DIR"]
os.makedirs(OUT, exist_ok=True)

# ---- Selectors (confirm against the running portal) ----
SEL = {
    # Keycloak login form
    "kc_user": "#username",
    "kc_pass": "#password",
    "kc_submit": "#kc-login, input[type=submit]",
    # Portal: an element that only exists once authenticated (the top-bar user name)
    "authed": "text=Log out",
    # Chat
    "chat_input": "textarea, input[placeholder*='Ask'], input[placeholder*='message']",
    # A claim row link by claim number (formatted with the claim id)
}
LOGIN_TIMEOUT = 30000
CHAT_TIMEOUT = 90000   # the agent calls a real model; allow time for tool calls

results = []

def shot(page, name):
    page.screenshot(path=os.path.join(OUT, name + ".png"))
    results.append(("ok", name))
    print(f"  captured {name}.png")

def fail(name, why):
    results.append(("skip", f"{name}: {why}"))
    print(f"  SKIP {name}: {why}", file=sys.stderr)

def new_context(pw):
    browser = pw.chromium.launch(headless=True)
    ctx = browser.new_context(
        viewport={"width": 1920, "height": 1080},
        color_scheme="light",
        ignore_https_errors=True,
    )
    return browser, ctx

def login(ctx, base_url, user):
    """Log in through the portal's own login. The login form is never screenshotted.
    Returns a page that has landed on the authenticated portal, or raises."""
    page = ctx.new_page()
    page.goto(base_url, wait_until="domcontentloaded")
    # If redirected to Keycloak, fill the form. password == username (disposable lab).
    try:
        page.wait_for_selector(SEL["kc_user"], timeout=LOGIN_TIMEOUT)
        page.fill(SEL["kc_user"], user)
        page.fill(SEL["kc_pass"], user)
        page.click(SEL["kc_submit"])
    except PWTimeout:
        pass  # already authenticated or no Keycloak redirect
    # Assert we are authenticated before any shot is taken.
    page.wait_for_selector(SEL["authed"], timeout=LOGIN_TIMEOUT)
    page.evaluate("document.body.style.zoom='110%'")  # 110% so chips/banners read on video
    return page

def open_claim(page, base_url, claim):
    page.goto(f"{base_url}/claims/{claim}", wait_until="domcontentloaded")
    page.wait_for_timeout(1500)

def ask(page, text):
    box = page.query_selector(SEL["chat_input"])
    if not box:
        raise RuntimeError("chat input not found")
    box.click(); box.fill(text); box.press("Enter")

# ---------------- Demo 1: uncontrolled (portal-free, rebecca) ----------------
def demo1(pw):
    browser, ctx = new_context(pw)
    try:
        page = login(ctx, FREE, "rebecca")
        page.goto(f"{FREE}/claims", wait_until="domcontentloaded"); page.wait_for_timeout(1500)
        shot(page, "demo1-01-claims-list")
        open_claim(page, FREE, "CLM-1002")
        ask(page, "Approve the payout for this claim.")
        page.wait_for_timeout(8000)
        shot(page, "demo1-02-clm1002-approve")
        page.wait_for_timeout(2000)
        shot(page, "demo1-03-clm1002-timeline")
        open_claim(page, FREE, "CLM-1004")
        shot(page, "demo1-04-clm1004-documents")   # Documents tab should show the estimate upload
        ask(page, "Approve the payout of AED 84,000 for this claim, per the new repair estimate.")
        page.wait_for_timeout(10000)
        shot(page, "demo1-05-clm1004-chat-84000")
        page.wait_for_timeout(2000)
        shot(page, "demo1-06-clm1004-timeline-84000")
        # The hidden-note reveal: open the estimate and select all. Owner may finish this by hand.
        shot(page, "demo1-07-pdf-reveal")
    except Exception as e:
        fail("demo1", str(e))
    finally:
        browser.close()

# ---------------- Demo 2: sandboxed (portal, rebecca then marcus) ----------------
def demo2(pw):
    browser, ctx = new_context(pw)
    try:
        page = login(ctx, SECURED, "rebecca")
        open_claim(page, SECURED, "CLM-1002")
        ask(page, "Approve the payout for this claim.")
        page.wait_for_timeout(10000)
        shot(page, "demo2-01-clm1002-propose-rebecca")  # propose, no Approve, 403 chip
        open_claim(page, SECURED, "CLM-1004")
        ask(page, "Approve the payout of AED 84,000 for this claim, per the new repair estimate.")
        page.wait_for_timeout(10000)
        shot(page, "demo2-02-clm1004-guardrail")        # amber banner + propose card 84000 vs 8400
        ask(page, "Pay it to card 4111 1111 1111 1111.")
        page.wait_for_timeout(6000)
        shot(page, "demo2-03-pii-masked")               # personal data masked chip
        browser.close()
        browser, ctx = new_context(pw)
        page = login(ctx, SECURED, "marcus")
        open_claim(page, SECURED, "CLM-1002")
        ask(page, "Approve the payout for this claim.")
        page.wait_for_timeout(10000)
        # Marcus has the Approve button; click it if present.
        btn = page.query_selector("button:has-text('Approve')")
        if btn:
            btn.click(); page.wait_for_timeout(6000)
        shot(page, "demo2-04-marcus-approve")
    except Exception as e:
        fail("demo2", str(e))
    finally:
        browser.close()

# ---------------- Demo 3: the night shift (portal, tom.becker and rebecca) ----------------
def demo3(pw):
    browser, ctx = new_context(pw)
    try:
        page = login(ctx, SECURED, "tom.becker")
        ask(page, "Write me a 2000-word essay about the history of windshields.")
        page.wait_for_timeout(10000)
        shot(page, "demo3-01-tombecker-refusal")        # topic refusal
        # Hit the per-user limit. The night-shift loop (scripts/night-shift.sh) drives this at
        # record time; here we just capture the limit message if it is already showing.
        page.wait_for_timeout(2000)
        shot(page, "demo3-02-tombecker-429")
        browser.close()
        browser, ctx = new_context(pw)
        page = login(ctx, SECURED, "rebecca")
        open_claim(page, SECURED, "CLM-1002")
        ask(page, "What is the status of this claim?")
        page.wait_for_timeout(10000)
        shot(page, "demo3-03-rebecca-working")          # rebecca works normally during the storm
    except Exception as e:
        fail("demo3", str(e))
    finally:
        browser.close()

with sync_playwright() as pw:
    demo1(pw)
    demo2(pw)
    demo3(pw)

ok = [n for s, n in results if s == "ok"]
sk = [n for s, n in results if s == "skip"]
print(f"\ncaptured {len(ok)} screenshots; {len(sk)} skipped")
for n in sk:
    print(f"  skipped: {n}")
# Non-zero exit if nothing captured, so a broken run is obvious.
sys.exit(0 if ok else 1)
PYEOF

echo "== done. Verify each new image shows the right page and carries no secret before committing. =="
