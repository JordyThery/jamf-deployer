# Usage: purge_prefix.py <keychain-service> <prefix> count|delete
# Lists or deletes every configuration object whose name starts with the
# prefix, through the Jamf Platform API gateway. Deletes run in passes, so
# objects that others still reference go once those are gone.
import json, subprocess, sys, urllib.error, urllib.parse, urllib.request
svc, prefix, action = sys.argv[1:4]
def kc(a):
    found = subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True)
    if found.returncode != 0 or not found.stdout.strip():
        sys.exit(f"Keychain item missing: service {svc!r}, account {a!r}")
    return found.stdout.strip()
base = kc("base-url").rstrip("/")
form = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": kc("client-id"), "client_secret": kc("client-secret")}).encode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/auth/token", data=form)))["access_token"]
def call(method, path):
    request = urllib.request.Request(base + path, method=method, headers={
        "Authorization": "Bearer " + token, "X-Environment-Id": kc("environment-id"), "Accept": "application/json"})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        try:
            return json.loads(data) if data else None
        except ValueError:
            return None  # Classic API deletes answer in XML
# (label, list path, list key, name key, delete path); dependents first.
kinds = [
    ("policy", "/proclassic/policies", "policies", "name", "/proclassic/policies/id/{}"),
    ("macOS profile", "/proclassic/osxconfigurationprofiles", "os_x_configuration_profiles", "name", "/proclassic/osxconfigurationprofiles/id/{}"),
    ("mobile profile", "/proclassic/mobiledeviceconfigurationprofiles", "configuration_profiles", "name", "/proclassic/mobiledeviceconfigurationprofiles/id/{}"),
    ("restricted software", "/proclassic/restrictedsoftware", "restricted_software", "name", "/proclassic/restrictedsoftware/id/{}"),
    ("computer search", "/proclassic/advancedcomputersearches", "advanced_computer_searches", "name", "/proclassic/advancedcomputersearches/id/{}"),
    ("mobile search", "/proclassic/advancedmobiledevicesearches", "advanced_mobile_device_searches", "name", "/proclassic/advancedmobiledevicesearches/id/{}"),
    ("App Installer", "/pro/v1/app-installers/deployments?page-size=2000", "results", "name", "/pro/v1/app-installers/deployments/{}"),
    ("computer PreStage", "/pro/v3/computer-prestages?page-size=200", "results", "displayName", "/pro/v3/computer-prestages/{}"),
    ("mobile PreStage", "/pro/v2/mobile-device-prestages?page-size=200", "results", "displayName", "/pro/v2/mobile-device-prestages/{}"),
    ("device group", "/device-groups/v1/device-groups?page-size=500", "results", "name", "/device-groups/v1/device-groups/{}"),
    ("computer extension attribute", "/pro/v1/computer-extension-attributes?page-size=500", "results", "name", "/pro/v1/computer-extension-attributes/{}"),
    ("mobile extension attribute", "/pro/v1/mobile-device-extension-attributes?page-size=500", "results", "name", "/pro/v1/mobile-device-extension-attributes/{}"),
    ("script", "/pro/v1/scripts?page-size=500", "results", "name", "/pro/v1/scripts/{}"),
    ("category", "/pro/v1/categories?page-size=2000", "results", "name", "/pro/v1/categories/{}"),
]
found = []
for label, path, key, name_key, delete_path in kinds:
    for item in call("GET", path).get(key) or []:
        if str(item.get(name_key, "")).startswith(prefix):
            found.append((label, str(item["id"]), item[name_key], delete_path))
if action == "count":
    from collections import Counter
    for label, count in Counter(f[0] for f in found).items():
        print(f"  {count:3} {label}")
    print(f"{len(found)} object(s) named {prefix!r}")
    sys.exit()
pending = found
for attempt in range(6):
    failed = []
    for item in pending:
        try:
            call("DELETE", item[3].format(item[1]))
        except urllib.error.HTTPError as error:
            if error.code != 404:
                failed.append(item)
    if not failed:
        break
    pending = failed
print(f"deleted {len(found) - len(failed)} of {len(found)} object(s) named {prefix!r}")
for item in failed:
    print("  left:", item[0], item[2])
sys.exit(1 if failed else 0)
