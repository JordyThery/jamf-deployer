# Usage: jpcall.py <service> <python statements using call(method, path, payload)>
import base64, json, subprocess, sys, urllib.request, urllib.error
svc = sys.argv[1]
kc = lambda a: subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True).stdout.strip()
base = "https://" + kc("jamfpro-fqdn")
basic = base64.b64encode((kc("jamfpro-username") + ":" + kc("jamfpro-password")).encode()).decode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/token", method="POST", headers={"Authorization": "Basic " + basic})))["token"]
def call(method, path, payload=None):
    request = urllib.request.Request(base + path, method=method, data=json.dumps(payload).encode() if payload is not None else None, headers={
        "Authorization": "Bearer " + token, "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return {"HTTP": e.code, "body": e.read().decode()[:600]}
try:
    exec(sys.argv[2])
finally:
    urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/invalidate-token", method="POST", headers={"Authorization": "Bearer " + token}))
