#!/usr/bin/env python3
"""Drive a real Nextcloud Login Flow v2 through the HomeVault panel (browser simulation)."""
import base64, http.cookiejar, json, re, ssl, sys, time, urllib.parse, urllib.request

PANEL = "https://127.0.0.1:38444"
NC = "https://127.0.0.1:38443"
ctx = ssl.create_default_context(cafile="root.crt")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    pass


def opener():
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                       urllib.request.HTTPCookieProcessor(jar)), jar


def req(op, method, url, data=None, headers=None, json_body=None):
    h = dict(headers or {})
    body = None
    if json_body is not None:
        body = json.dumps(json_body).encode()
        h["Content-Type"] = "application/json"
    elif data is not None:
        body = urllib.parse.urlencode(data).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    r = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with op.open(r, timeout=60) as resp:
            return resp.status, resp.read().decode("utf-8", "replace"), resp
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e


def initial_state(html, key):
    m = re.search(r'id="initial-state-core-%s" value="([^"]+)"' % key, html)
    if not m:
        raise SystemExit("initial state %s not found" % key)
    return json.loads(base64.b64decode(m.group(1)))


def requesttoken(html):
    m = re.search(r'data-requesttoken="([^"]+)"', html)
    if not m:
        raise SystemExit("requesttoken not found")
    return m.group(1)


def panel_login_flow(panel_op, user, password, expect_ok=True):
    same = {"Origin": PANEL, "Sec-Fetch-Site": "same-origin"}
    st, body, _ = req(panel_op, "POST", PANEL + "/api/auth/flow", headers=same, json_body={})
    assert st == 200, (st, body)
    login_url = json.loads(body)["login_url"]
    print("login_url:", re.sub(r"flow/.*", "flow/<token>", login_url))
    assert login_url.startswith(NC + "/login/v2/flow/"), login_url

    # --- the "browser" (WebView) part on Nextcloud
    b, _ = opener()
    st, html, _ = req(b, "GET", login_url)
    assert st == 200, st
    auth = initial_state(html, "loginFlowAuth")
    print("auth picker: client=%r" % auth["client"])
    grant_url = urllib.parse.urlsplit(auth["loginRedirectUrl"])
    redirect = grant_url.path + ("?" + grant_url.query if grant_url.query else "")
    st, html, _ = req(b, "GET", NC + "/login?" + urllib.parse.urlencode({"redirect_url": redirect}))
    tok = requesttoken(html)
    st, html, resp = req(b, "POST", NC + "/login", data={
        "user": user, "password": password, "requesttoken": tok, "redirect_url": redirect,
        "timezone": "Asia/Shanghai", "timezone_offset": "8"}, headers={"Origin": NC})
    assert st == 200, (st, html[:300])
    grant = initial_state(html, "loginFlowGrant")
    print("grant page for user:", grant["userId"])
    st, html, _ = req(b, "POST", grant["actionUrl"], data={"stateToken": grant["stateToken"],
                                                            "requesttoken": requesttoken(html)}, headers={"Origin": NC})
    assert st == 200 and '"done"' in base64.b64decode(re.search(r'id="initial-state-core-loginFlowState" value="([^"]+)"', html).group(1)).decode(), st
    print("nextcloud: account connected")

    # --- back in the panel: poll
    for _ in range(30):
        st, body, _ = req(panel_op, "POST", PANEL + "/api/auth/flow/poll", headers=same, json_body={})
        d = json.loads(body)
        if d["state"] != "pending":
            break
        time.sleep(1)
    print("panel poll:", {k: v for k, v in d.items() if k != "csrf"})
    if expect_ok:
        assert d["state"] == "ok", d
        return d["csrf"]
    assert d["state"] == "failed", d
    return None


if __name__ == "__main__":
    op, jar = opener()
    csrf = panel_login_flow(op, sys.argv[1], sys.argv[2], expect_ok=(sys.argv[3] == "ok"))
    if csrf:
        cookies = {c.name: c.value for c in jar}
        json.dump({"csrf": csrf, "cookie": cookies.get("__Host-hvpanel", "")}, open("session.json", "w"))
        print("session saved; cookie attrs:", [(c.name, c.secure, c.has_nonstandard_attr("HttpOnly"), c.get_nonstandard_attr("SameSite")) for c in jar])
