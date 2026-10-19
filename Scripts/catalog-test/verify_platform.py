# Usage: verify_platform.py <keychain-service> <prefix> present|absent
# Checks the Platform-only objects (Blueprint, compliance benchmark).
import json, subprocess, sys, urllib.parse, urllib.request
svc, prefix, expect = sys.argv[1:4]
kc = lambda a: subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True).stdout.strip()
base = kc("base-url").rstrip("/")
form = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": kc("client-id"), "client_secret": kc("client-secret")}).encode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/auth/token", data=form)))["access_token"]
def get(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token, "X-Environment-Id": kc("environment-id"), "Accept": "application/json"})
    return json.load(urllib.request.urlopen(request))
blueprints = [b["name"] for b in get("/blueprints/v1/blueprints")["results"]]
benchmarks = [b["title"] for b in get("/compliance-benchmarks/v1/benchmarks")["benchmarks"]]
failures = 0
for label, present in [(f"blueprint {prefix}Software Updates", prefix + "Software Updates" in blueprints),
                       (f"benchmark {prefix}CIS Level 1", prefix + "CIS Level 1" in benchmarks)]:
    ok = present == (expect == "present")
    failures += not ok
    print(("  ok   " if ok else "  FAIL ") + label + (" exists" if expect == "present" else " is gone"))
print(f"{failures} failure(s)")
sys.exit(1 if failures else 0)
