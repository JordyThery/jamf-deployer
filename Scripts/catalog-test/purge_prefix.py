# Usage: purge_prefix.py <keychain-service> <prefix> [count|delete]
# Lists (count, the default) or deletes every configuration object whose name
# starts with the prefix, through the Jamf Platform API gateway. Deletes run
# in passes, so objects that others still reference go once those are gone.
# The prefix must be a test prefix (tenant_guard.py), and delete runs only for
# a full-access, non-production tenant on the release-check allow-list.
import json, os, sys, urllib.error, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tenant_guard

USAGE = "purge_prefix.py <keychain-service> <prefix> [count|delete]"
# (label, list path, list key, name key, delete path); dependents first.
KINDS = [
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


def parse_args(argv):
    """(service, prefix, action): count unless the action is exactly "delete"."""
    if len(argv) not in (2, 3):
        raise tenant_guard.Usage(USAGE)
    service, prefix = argv[0], argv[1]
    action = argv[2] if len(argv) == 3 else "count"
    if action not in ("count", "delete"):
        raise tenant_guard.Usage(f"unknown action {action!r}; {USAGE}")
    if not service.strip():
        raise tenant_guard.Usage(USAGE)
    return service, tenant_guard.check_prefix(prefix), action


def connect(kc):
    """call(method, path) through the Platform gateway, signed in with the service's client."""
    base = kc("base-url").rstrip("/")
    form = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": kc("client-id"), "client_secret": kc("client-secret")}).encode()
    token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/auth/token", data=form)))["access_token"]
    environment = kc("environment-id")

    def call(method, path):
        request = urllib.request.Request(base + path, method=method, headers={
            "Authorization": "Bearer " + token, "X-Environment-Id": environment, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(request) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if method == "DELETE" and error.code == 404:
                return None
            raise
        try:
            return json.loads(data) if data else None
        except ValueError:
            return None  # Classic API deletes answer in XML
    return call


def purge(argv, kc=None, connect=connect, tenants=None, out=print):
    """Returns the exit status. kc, connect and tenants are injectable for tests."""
    service, prefix, action = parse_args(argv)
    kc = kc or (lambda account: tenant_guard.read_keychain(service, account))
    if action == "delete":
        # Before signing in, so nothing is sent for a tenant that isn't allowed.
        tenant_guard.require_writable(service, "jamfPlatform", kc("environment-id"), tenants)
    call = connect(kc)
    found = []
    for label, path, key, name_key, delete_path in KINDS:
        for item in (call("GET", path) or {}).get(key) or []:
            if str(item.get(name_key, "")).startswith(prefix):
                found.append((label, str(item["id"]), item[name_key], delete_path))
    if action == "count":
        from collections import Counter
        for label, count in Counter(f[0] for f in found).items():
            out(f"  {count:3} {label}")
        out(f"{len(found)} object(s) named {prefix!r}")
        return 0
    pending, failed = found, []
    for attempt in range(6):
        failed = []
        for item in pending:
            if not item[2].startswith(prefix):  # never delete an object without the prefix
                continue
            try:
                call("DELETE", item[3].format(item[1]))
            except urllib.error.HTTPError:
                failed.append(item)
        if not failed:
            break
        pending = failed
    out(f"deleted {len(found) - len(failed)} of {len(found)} object(s) named {prefix!r}")
    for item in failed:
        out("  left: " + item[0] + " " + item[2])
    return 1 if failed else 0


if __name__ == "__main__":
    status = [0]
    tenant_guard.run(lambda: status.__setitem__(0, purge(sys.argv[1:])))
    sys.exit(status[0])
