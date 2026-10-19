# Usage: protectcall.py <service> <python statements using gql(query, variables)>
# Signs in to Jamf Protect with protect-url, protect-client-id and
# protect-client-secret from the login Keychain; nothing is written anywhere.
import json, subprocess, sys, urllib.request, urllib.error
svc = sys.argv[1]
def kc(a):
    return subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True).stdout.strip()
base = kc("protect-url")
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/token", data=json.dumps(
    {"client_id": kc("protect-client-id"), "password": kc("protect-client-secret")}).encode(),
    headers={"Content-Type": "application/json"})))["access_token"]
def gql(query, variables=None):
    request = urllib.request.Request(base + "/app", data=json.dumps({"query": query, "variables": variables or {}}).encode(),
                                     headers={"Content-Type": "application/json", "Authorization": token})
    try:
        return json.load(urllib.request.urlopen(request))
    except urllib.error.HTTPError as e:
        return {"HTTP": e.code, "body": e.read().decode()[:600]}
def items(query, order):
    found = gql(query, {"d": "ASC", "f": order}).get("data") or {}
    return next(iter(found.values()), {}).get("items", [])
exec(sys.argv[2])
