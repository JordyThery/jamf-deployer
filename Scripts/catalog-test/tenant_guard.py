# Shared guards for the catalog-test helpers that change a tenant:
# - names they act on carry a test prefix (never empty, never "JD - "), and
# - the Keychain service they sign in with belongs to a full-access,
#   non-production tenant on JTKit's release-check allow-list, and points at
#   that tenant's environment ID or Jamf Pro host.
# The allow-list lives outside every repo, readable by its owner only; deny by
# default. Nothing here prints a secret.
import json, os, re, subprocess, sys

ALLOWLIST = os.path.expanduser("~/Library/Application Support/JTKit Release Check/allowlist.json")
MIN_PREFIX_LENGTH = 3
# The UI test prefixes ("UIC - ", "UIF - ", "UIT RN - ") and the live checks' JTKTEST.
TEST_PREFIX = re.compile(r"^(UI[A-Z]+( [A-Z]+)* - |JTKTEST)")


class Refused(Exception):
    """A guard stopped the helper before it changed anything."""


class Usage(Exception):
    """The helper was called with arguments it doesn't understand."""


def check_prefix(prefix):
    """Refuses an empty, short or non-test prefix: a prefix decides what gets changed or deleted."""
    if len(prefix.strip()) < MIN_PREFIX_LENGTH:
        raise Refused(f"The prefix {prefix!r} is shorter than {MIN_PREFIX_LENGTH} characters")
    if not TEST_PREFIX.match(prefix):
        raise Refused(f"The prefix {prefix!r} doesn’t look like a test prefix (UI… - or JTKTEST)")
    return prefix


def read_keychain(service, account):
    found = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                           capture_output=True, text=True)
    value = found.stdout.strip()
    if found.returncode != 0 or not value:
        sys.exit(f"Keychain item missing: service {service!r}, account {account!r}")
    return value


def load_allowlist(path=None):
    """The allow-list's tenants, after the same checks JTKit's release check makes."""
    path = path or ALLOWLIST
    if not os.path.isfile(path):
        raise Refused(f"No allow-list at {path}")
    if os.stat(path).st_mode & 0o077:
        raise Refused(f"The allow-list must be readable by you only (chmod 600): {path}")
    folder = os.path.dirname(os.path.abspath(path))
    while folder != "/":
        if os.path.exists(os.path.join(folder, ".git")):
            raise Refused(f"The allow-list lies inside a git work tree: {path}")
        folder = os.path.dirname(folder)
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError as error:
        raise Refused(f"The allow-list can’t be read: {error}")
    if data.get("version") != 1:
        raise Refused(f"The allow-list’s version {data.get('version')!r} isn’t supported")
    return data.get("tenants") or []


def host_of(value):
    """A Jamf Pro address as a bare lowercased host ("https://x.example.com/" → "x.example.com")."""
    value = value.strip().lower()
    for scheme in ("https://", "http://"):
        if value.startswith(scheme):
            value = value[len(scheme):]
    return value.split("/", 1)[0]


def require_writable(keychain_service, service, identity, tenants=None):
    """The allow-list role that may be changed through this Keychain service, or Refused.

    service is "jamfPlatform" (identity: the environment ID) or "jamfPro"
    (identity: the Jamf Pro host). The entry must name this Keychain service,
    match the identity, have full access and not be production."""
    tenants = load_allowlist() if tenants is None else tenants
    identity = identity.strip().lower() if service == "jamfPlatform" else host_of(identity)
    matches = []
    for entry in tenants:
        if entry.get("keychainService") != keychain_service or entry.get("service") != service:
            continue
        if service == "jamfPlatform":
            known = [str(entry.get("environmentID") or "").lower()]
        else:
            known = [host_of(h) for h in [entry.get("host")] + list(entry.get("aliases") or []) if h]
        if identity and identity in known:
            matches.append(entry)
    if not matches:
        raise Refused(f"Keychain service {keychain_service!r} isn’t a {service} tenant on the allow-list "
                      "(or points at a different tenant than the allow-list names)")
    for entry in matches:
        if entry.get("access") != "full" or entry.get("production"):
            raise Refused(f"Allow-list role {entry.get('role')!r} may not be changed by these helpers "
                          f"(access {entry.get('access')!r}{', production' if entry.get('production') else ''})")
    return matches[0].get("role")


def run(main):
    """Runs a helper's main(), turning guard failures into an exit status: 2 for usage, 1 for refused."""
    try:
        main()
    except Usage as error:
        print(f"Usage: {error}", file=sys.stderr)
        sys.exit(2)
    except Refused as error:
        print(f"Refused: {error}", file=sys.stderr)
        sys.exit(1)
