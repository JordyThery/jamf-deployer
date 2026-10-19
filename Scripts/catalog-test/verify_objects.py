# Usage: verify_objects.py <keychain-service> <prefix> [present|absent]
# Checks every object the demo catalog creates, through the Jamf Pro API
# (plus the Classic API where Jamf has no Jamf Pro API endpoint).
import base64, json, subprocess, sys, urllib.request, urllib.error

svc, prefix = sys.argv[1], sys.argv[2]
expect = sys.argv[3] if len(sys.argv) > 3 else "present"
def kc(a):
    found = subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True)
    value = found.stdout.strip()
    if found.returncode != 0 or not value:
        sys.exit(f"Keychain item missing: service {svc!r}, account {a!r}")
    return value
base = "https://" + kc("jamfpro-fqdn")
basic = base64.b64encode((kc("jamfpro-username") + ":" + kc("jamfpro-password")).encode()).decode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/token", method="POST", headers={"Authorization": "Basic " + basic})))["token"]

def get(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read())

def named(items, key="name"):
    return {i[key]: i for i in items if str(i.get(key, "")).startswith(prefix)}

failures = []
def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)

found = {
    "categories": named(get("/api/v1/categories?page-size=2000")["results"]),
    "computer groups": named(get("/api/v1/computer-groups")),
    "extension attributes": named(get("/api/v1/computer-extension-attributes?page-size=2000")["results"]),
    "scripts": named(get("/api/v1/scripts?page-size=2000")["results"]),
    "policies": named(get("/JSSResource/policies")["policies"]),
    "disk encryption": named(get("/JSSResource/diskencryptionconfigurations")["disk_encryption_configurations"]),
    "mobile groups": named(get("/api/v1/mobile-device-groups")),
    "mobile profiles": named(get("/JSSResource/mobiledeviceconfigurationprofiles")["configuration_profiles"]),
    "computer prestages": named(get("/api/v3/computer-prestages?page-size=200")["results"], "displayName"),
    "mobile prestages": named(get("/api/v3/mobile-device-prestages?page-size=200")["results"], "displayName"),
    "app installers": named(get("/api/v1/app-installers/deployments?page-size=2000")["results"]),
}
expected = {
    "categories": ["Applications", "Enrollment", "Maintenance", "Security"],
    "computer groups": ["Pilot", "All Managed Macs", "Laptops", "Desktops", "Apple Silicon Macs",
                        "Macs on current macOS", "Macs below minimum macOS"],
    "extension attributes": ["Baseline Marker", "Deployment Ring"],
    "scripts": ["Install Rosetta 2", "Flush DNS cache"],
    "policies": ["Enable FileVault", "Install Rosetta 2", "Update inventory", "Flush DNS cache"],
    "disk encryption": ["FileVault — Individual Key"],
    "mobile groups": ["Supervised iPads", "Supervised iPhones"],
    "mobile profiles": ["Passcode"],
    "computer prestages": ["Standard Enrollment"],
    "mobile prestages": ["iPad and iPhone Enrollment"],
    "app installers": ["Google Chrome"],
}
for kind, names in expected.items():
    for name in names:
        present = prefix + name in found[kind]
        check(f"{kind}: {prefix}{name} {'exists' if expect == 'present' else 'is gone'}", present == (expect == "present"))

if expect == "present":
    groups = found["computer groups"]
    check("Pilot is static", groups.get(prefix + "Pilot", {}).get("smartGroup") is False)
    check("Laptops is smart", groups.get(prefix + "Laptops", {}).get("smartGroup") is True)
    cats = found["categories"]
    check("categories have priority 9", all(c["priority"] == 9 for c in cats.values()), str([c["priority"] for c in cats.values()]))
    ea = found["extension attributes"].get(prefix + "Deployment Ring", {})
    check("Deployment Ring is a pop-up with Pilot/Production", ea.get("inputType") == "POPUP" and ea.get("popupMenuChoices") == ["Pilot", "Production"], str(ea.get("popupMenuChoices")))
    fv = found["policies"].get(prefix + "Enable FileVault")
    if fv:
        detail = get(f"/JSSResource/policies/id/{fv['id']}")["policy"]
        check("FileVault policy runs at login, once per computer", detail["general"]["trigger_login"] and detail["general"]["frequency"] == "Once per computer")
        check("FileVault policy is scoped to Pilot", [g["name"] for g in detail["scope"]["computer_groups"]] == [prefix + "Pilot"])
        check("FileVault policy is filed under Security", detail["general"]["category"]["name"] == prefix + "Security")
        check("FileVault policy applies the configuration", detail["disk_encryption"]["action"] == "apply")
    ro = found["policies"].get(prefix + "Install Rosetta 2")
    if ro:
        detail = get(f"/JSSResource/policies/id/{ro['id']}")["policy"]
        check("Rosetta policy runs its script", [s["name"] for s in detail["scripts"]] == [prefix + "Install Rosetta 2"])
        check("Rosetta policy is scoped to Apple Silicon Macs", [g["name"] for g in detail["scope"]["computer_groups"]] == [prefix + "Apple Silicon Macs"])
    ui = found["policies"].get(prefix + "Update inventory")
    if ui:
        detail = get(f"/JSSResource/policies/id/{ui['id']}")["policy"]
        check("Update inventory is a Self Service item", detail["self_service"]["use_for_self_service"])
        check("Update inventory updates inventory", detail["maintenance"]["recon"])
    pc = found["mobile profiles"].get(prefix + "Passcode")
    if pc:
        detail = get(f"/JSSResource/mobiledeviceconfigurationprofiles/id/{pc['id']}")["configuration_profile"]
        check("Passcode profile targets Supervised iPads", [g["name"] for g in detail["scope"]["mobile_device_groups"]] == [prefix + "Supervised iPads"])
        check("Passcode profile requires 6 characters", "<integer>6</integer>" in detail["general"]["payloads"])
    ps = found["computer prestages"].get(prefix + "Standard Enrollment")
    if ps:
        check("Computer PreStage is mandatory and not removable", ps["mandatory"] and not ps["mdmRemovable"])
        check("Computer PreStage skips Apple ID and Siri", ps["skipSetupItems"].get("AppleID") and ps["skipSetupItems"].get("Siri"), str(ps["skipSetupItems"]))
    ms = found["mobile prestages"].get(prefix + "iPad and iPhone Enrollment")
    if ms:
        check("Mobile PreStage is supervised", ms["supervised"])
    ai = found["app installers"].get(prefix + "Google Chrome")
    if ai:
        check("Chrome App Installer is scoped to All Managed Macs", str(ai.get("smartGroup", {}).get("id")) == str(found["computer groups"][prefix + "All Managed Macs"]["id"]))

urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/invalidate-token", method="POST", headers={"Authorization": "Bearer " + token}))
print(f"{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
