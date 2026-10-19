# Usage: settings.py <keychain-service> snapshot|restore|show <file>
# Snapshots and restores the tenant-wide settings the catalog blocks manage,
# through the Jamf Pro API with the Keychain's jamfpro-* credentials.
import base64, json, subprocess, sys, urllib.request

svc, action, path = sys.argv[1:4]
kc = lambda a: subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True).stdout.strip()
base = "https://" + kc("jamfpro-fqdn")
basic = base64.b64encode((kc("jamfpro-username") + ":" + kc("jamfpro-password")).encode()).decode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/token", method="POST", headers={"Authorization": "Basic " + basic})))["token"]

def call(method, path, payload=None):
    request = urllib.request.Request(base + path, method=method, data=json.dumps(payload).encode() if payload is not None else None, headers={
        "Authorization": "Bearer " + token, "Accept": "application/json", "Content-Type": "application/json"})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        return json.loads(data) if data else None

# name: (read path, write method, write path)
ENDPOINTS = {
    "check-in": ("/api/v3/check-in", "PUT", "/api/v3/check-in"),
    "inventory-collection": ("/api/v2/computer-inventory-collection-settings", "PATCH", "/api/v2/computer-inventory-collection-settings"),
    "laps": ("/api/v2/local-admin-password/settings", "PUT", "/api/v2/local-admin-password/settings"),
    "reenrollment": ("/api/v1/reenrollment", "PUT", "/api/v1/reenrollment"),
    "self-service": ("/api/v1/self-service/settings", "PUT", "/api/v1/self-service/settings"),
}
try:
    if action == "snapshot":
        snapshot = {name: call("GET", read) for name, (read, _, _) in ENDPOINTS.items()}
        json.dump(snapshot, open(path, "w"), indent=1)
        print("saved", path)
    elif action == "show":
        current = {name: call("GET", read) for name, (read, _, _) in ENDPOINTS.items()}
        saved = json.load(open(path))
        for name in ENDPOINTS:
            print(name, "unchanged" if current[name] == saved[name] else f"CHANGED\n  saved:   {saved[name]}\n  current: {current[name]}")
    elif action == "restore":
        saved = json.load(open(path))
        failed = []
        for name, (_, method, write) in ENDPOINTS.items():
            body = saved[name]
            if name == "inventory-collection":
                body = {"computerInventoryCollectionPreferences": body["computerInventoryCollectionPreferences"]}
            try:
                call(method, write, body)
                print("restored", name)
            except Exception as error:
                print("COULD NOT RESTORE", name, error)
                failed.append(name)
        if failed:
            sys.exit(1)
finally:
    urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/invalidate-token", method="POST", headers={"Authorization": "Bearer " + token}))
