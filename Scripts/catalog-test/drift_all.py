# Usage: drift_all.py <keychain-service> <prefix>
# Changes one field on every object type the demo catalog creates, directly
# in Jamf, so a check for changes has something to find for each type.
import base64, json, subprocess, sys, urllib.request, urllib.error

svc, prefix = sys.argv[1], sys.argv[2]
def kc(a):
    found = subprocess.run(["security", "find-generic-password", "-s", svc, "-a", a, "-w"], capture_output=True, text=True)
    value = found.stdout.strip()
    if found.returncode != 0 or not value:
        sys.exit(f"Keychain item missing: service {svc!r}, account {a!r}")
    return value
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

def find(items, name, key="name"):
    return next(i for i in items if i[key] == prefix + name)

def step(label, action):
    try:
        action()
        print("  changed", label)
    except urllib.error.HTTPError as error:
        print("  FAILED ", label, error.code, error.read().decode()[:300])
    except StopIteration:
        print("  MISSING", label)

def category():
    c = find(call("GET", "/api/v1/categories?page-size=2000")["results"], "Security")
    call("PUT", f"/api/v1/categories/{c['id']}", {"name": c["name"], "priority": 3})

def smart_group():
    g = find(call("GET", "/api/v1/computer-groups"), "Laptops")
    detail = call("GET", f"/api/v2/computer-groups/smart-groups/{g['id']}")
    detail["criteria"][0]["value"] = "MacBook"
    call("PUT", f"/api/v2/computer-groups/smart-groups/{g['id']}", {k: detail[k] for k in ("name", "criteria", "siteId", "description") if k in detail})

def static_group():
    g = find(call("GET", "/api/v1/computer-groups"), "Pilot")
    call("PUT", f"/JSSResource/computergroups/id/{g['id']}", xml=f"<computer_group><name>{prefix}Pilot Renamed</name></computer_group>")

def extension_attribute():
    e = find(call("GET", "/api/v1/computer-extension-attributes?page-size=2000")["results"], "Baseline Marker")
    e["description"] = "Changed in Jamf"
    call("PUT", f"/api/v1/computer-extension-attributes/{e['id']}", e)

def script():
    s = find(call("GET", "/api/v1/scripts?page-size=2000")["results"], "Flush DNS cache")
    s["info"] = "Changed in Jamf"
    call("PUT", f"/api/v1/scripts/{s['id']}", s)

def policy():
    p = find(call("GET", "/JSSResource/policies")["policies"], "Update inventory")
    call("PUT", f"/JSSResource/policies/id/{p['id']}", xml="<policy><general><frequency>Once per computer</frequency></general></policy>")

def disk_encryption():
    d = find(call("GET", "/JSSResource/diskencryptionconfigurations")["disk_encryption_configurations"], "FileVault — Individual Key")
    call("PUT", f"/JSSResource/diskencryptionconfigurations/id/{d['id']}", xml="<disk_encryption_configuration><file_vault_enabled_users>Management Account</file_vault_enabled_users></disk_encryption_configuration>")

def mobile_group():
    g = find(call("GET", "/api/v1/mobile-device-groups"), "Supervised iPhones")
    call("PUT", f"/JSSResource/mobiledevicegroups/id/{g['id']}", xml=f"<mobile_device_group><name>{prefix}Supervised iPhones Renamed</name></mobile_device_group>")

def mobile_profile():
    p = find(call("GET", "/JSSResource/mobiledeviceconfigurationprofiles")["configuration_profiles"], "Passcode")
    call("PUT", f"/JSSResource/mobiledeviceconfigurationprofiles/id/{p['id']}", xml="<configuration_profile><general><description>Changed in Jamf</description></general></configuration_profile>")

def computer_prestage():
    p = find(call("GET", "/api/v3/computer-prestages?page-size=200")["results"], "Standard Enrollment", "displayName")
    p["supportEmailAddress"] = "changed@example.com"
    call("PUT", f"/api/v3/computer-prestages/{p['id']}", p)

def mobile_prestage():
    p = find(call("GET", "/api/v3/mobile-device-prestages?page-size=200")["results"], "iPad and iPhone Enrollment", "displayName")
    p["supportPhoneNumber"] = "+1 555 0100"
    call("PUT", f"/api/v3/mobile-device-prestages/{p['id']}", p)

def app_installer():
    a = find(call("GET", "/api/v1/app-installers/deployments?page-size=2000")["results"], "Google Chrome")
    detail = call("GET", f"/api/v1/app-installers/deployments/{a['id']}")
    detail["updateBehavior"] = "MANUAL"
    call("PUT", f"/api/v1/app-installers/deployments/{a['id']}", detail)

def check_in():
    c = call("GET", "/api/v3/check-in"); c["checkInFrequency"] = 30
    call("PUT", "/api/v3/check-in", c)

def inventory():
    call("PATCH", "/api/v2/computer-inventory-collection-settings", {"computerInventoryCollectionPreferences": {"monitorApplicationUsage": False}})

def laps():
    l = call("GET", "/api/v2/local-admin-password/settings"); l["passwordRotationTime"] = 10800
    call("PUT", "/api/v2/local-admin-password/settings", l)

def reenrollment():
    r = call("GET", "/api/v1/reenrollment"); r["flushMDMQueue"] = "DELETE_NOTHING"
    call("PUT", "/api/v1/reenrollment", r)

def self_service():
    s = call("GET", "/api/v1/self-service/settings"); s["configurationSettings"]["defaultLandingPage"] = "BROWSE"
    call("PUT", "/api/v1/self-service/settings", s)

for label, action in [
    ("category priority", category), ("smart group criteria", smart_group), ("static group name", static_group),
    ("extension attribute description", extension_attribute), ("script info", script), ("policy frequency", policy),
    ("disk encryption users", disk_encryption), ("mobile group name", mobile_group), ("mobile profile description", mobile_profile),
    ("computer PreStage support email", computer_prestage), ("mobile PreStage support phone", mobile_prestage),
    ("App Installer update behavior", app_installer), ("check-in frequency", check_in), ("inventory app usage", inventory),
    ("LAPS rotation after viewing", laps), ("re-enrollment history", reenrollment), ("Self Service landing page", self_service),
]:
    step(label, action)
urllib.request.urlopen(urllib.request.Request(base + "/api/v1/auth/invalidate-token", method="POST", headers={"Authorization": "Bearer " + token}))
