# Usage: adopt_objects.py <keychain-service> <prefix> create|change|delete
# Six objects of different types for the adoption test, made, changed and
# deleted directly through the Jamf Pro API: a category, a script, a smart
# and a static computer group, an extension attribute, and a policy that
# uses the script, the category and the smart group.
import base64, json, subprocess, sys, urllib.request, urllib.error

svc, prefix, action = sys.argv[1:4]
kc = lambda a: subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True).stdout.strip()
base = "https://" + kc("jamfpro-fqdn")
basic = base64.b64encode((kc("jamfpro-username") + ":" + kc("jamfpro-password")).encode()).decode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/token", method="POST", headers={"Authorization": "Basic " + basic})))["token"]

def call(method, path, payload=None, xml=None):
    data = xml.encode() if xml else (json.dumps(payload).encode() if payload is not None else None)
    request = urllib.request.Request(base + path, method=method, data=data, headers={
        "Authorization": "Bearer " + token, "Accept": "application/json",
        "Content-Type": "application/xml" if xml else "application/json"})
    with urllib.request.urlopen(request) as response:
        body = response.read()
        return json.loads(body) if body and body.strip().startswith((b"{", b"[")) else None

name = lambda kind: f"{prefix}Adopt {kind}"

def ids():
    found = {}
    for c in call("GET", "/api/v1/categories?page-size=2000")["results"]:
        if c["name"] == name("Category"): found["category"] = c["id"]
    for s in call("GET", "/api/v1/scripts?page-size=2000")["results"]:
        if s["name"] == name("Script"): found["script"] = s["id"]
    for g in call("GET", "/api/v1/computer-groups"):
        if g["name"] == name("Smart Group"): found["smart"] = g["id"]
        if g["name"] == name("Static Group"): found["static"] = g["id"]
    for e in call("GET", "/api/v1/computer-extension-attributes?page-size=2000")["results"]:
        if e["name"] == name("Extension Attribute"): found["ea"] = e["id"]
    for p in call("GET", "/JSSResource/policies")["policies"]:
        if p["name"] == name("Policy"): found["policy"] = p["id"]
    return found

try:
    if action == "create":
        category = call("POST", "/api/v1/categories", {"name": name("Category"), "priority": 9})["id"]
        script = call("POST", "/api/v1/scripts", {"name": name("Script"), "priority": "AFTER", "categoryId": category,
                                                  "scriptContents": "#!/bin/sh\necho adopted\n"})["id"]
        smart = call("POST", "/api/v2/computer-groups/smart-groups", {"name": name("Smart Group"), "criteria": [
            {"name": "Operating System", "priority": 0, "andOr": "and", "searchType": "like", "value": "macOS",
             "openingParen": False, "closingParen": False}]})["id"]
        call("POST", "/JSSResource/computergroups/id/0", xml=f"<computer_group><name>{name('Static Group')}</name><is_smart>false</is_smart></computer_group>")
        call("POST", "/api/v1/computer-extension-attributes", {"name": name("Extension Attribute"), "enabled": True,
             "dataType": "STRING", "inputType": "TEXT", "inventoryDisplayType": "EXTENSION_ATTRIBUTES", "description": "adoption test"})
        call("POST", "/JSSResource/policies/id/0", xml=f"""<policy><general><name>{name('Policy')}</name><enabled>true</enabled>
<frequency>Ongoing</frequency><category><id>{category}</id></category></general>
<scope><computer_groups><computer_group><id>{smart}</id></computer_group></computer_groups></scope>
<scripts><size>1</size><script><id>{script}</id><priority>After</priority></script></scripts></policy>""")
        print("  created", sorted(ids()))
    elif action == "change":
        found = ids()
        call("PUT", f"/JSSResource/policies/id/{found['policy']}", xml="<policy><general><frequency>Once per computer</frequency></general></policy>")
        script = call("GET", f"/api/v1/scripts/{found['script']}")
        script["info"] = "Changed in Jamf"
        call("PUT", f"/api/v1/scripts/{found['script']}", script)
        print("  changed the adopted policy and script")
    elif action == "delete":
        found = ids()
        for key, path in [("policy", "/JSSResource/policies/id/"), ("ea", "/api/v1/computer-extension-attributes/"),
                          ("static", "/JSSResource/computergroups/id/"), ("smart", "/api/v2/computer-groups/smart-groups/"),
                          ("script", "/api/v1/scripts/"), ("category", "/api/v1/categories/")]:
            if key in found:
                call("DELETE", path + str(found[key]))
                print("  deleted", key)
except urllib.error.HTTPError as error:
    print("  FAILED", action, error.code, error.read().decode()[:300])
    sys.exit(1)
finally:
    urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/invalidate-token", method="POST", headers={"Authorization": "Bearer " + token}))
