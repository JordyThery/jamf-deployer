# Tests for the catalog-test guards; no network, no Keychain, no real allow-list.
#   /usr/bin/python3 -I -m unittest discover -s Scripts/catalog-test/tests
import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tenant_guard, purge_prefix

ENVIRONMENT = "00000000-0000-4000-8000-000000000001"
TENANTS = [
    {"role": "jamf-test-a", "service": "jamfPlatform", "region": "us", "environmentID": ENVIRONMENT,
     "access": "full", "production": False, "keychainService": "Example-TestA"},
    {"role": "jamf-test-a", "service": "jamfPro", "host": "test-a.example.com",
     "access": "full", "production": False, "keychainService": "Example-TestA"},
    {"role": "jamfpro-readonly", "service": "jamfPlatform", "region": "us", "environmentID": "00000000-0000-4000-8000-000000000002",
     "access": "readOnly", "production": False, "keychainService": "Example-ReadOnly"},
]


class FakeTenant:
    """Keychain items and a Platform gateway that record every call."""
    def __init__(self, environment=ENVIRONMENT):
        self.items = {"environment-id": environment, "base-url": "https://example.invalid"}
        self.calls = []

    def kc(self, account):
        return self.items[account]

    def connect(self, kc):
        def call(method, path):
            self.calls.append((method, path))
            if method == "GET" and path.startswith("/proclassic/policies"):
                return {"policies": [{"id": 1, "name": "UIF - Policy"}, {"id": 2, "name": "JD - Policy"}]}
            return None
        return call


class PrefixTests(unittest.TestCase):
    def test_empty_prefix_is_refused(self):
        with self.assertRaises(tenant_guard.Refused):
            tenant_guard.check_prefix("")
        with self.assertRaises(tenant_guard.Refused):
            purge_prefix.parse_args(["Example-TestA", "", "delete"])

    def test_short_prefix_is_refused(self):
        for prefix in ("U", "UI", "  ", "J -"):
            with self.assertRaises(tenant_guard.Refused, msg=prefix):
                tenant_guard.check_prefix(prefix)

    def test_non_test_prefix_is_refused(self):
        for prefix in ("JD - ", "Contoso", "cont"):
            with self.assertRaises(tenant_guard.Refused, msg=prefix):
                tenant_guard.check_prefix(prefix)

    def test_test_prefixes_pass(self):
        for prefix in ("UIF - ", "UIC - ", "UIT RN - ", "JTKTEST-"):
            self.assertEqual(tenant_guard.check_prefix(prefix), prefix)


class ActionTests(unittest.TestCase):
    def test_count_by_default(self):
        self.assertEqual(purge_prefix.parse_args(["Example-TestA", "UIF - "])[2], "count")
        tenant = FakeTenant()
        lines = []
        status = purge_prefix.purge(["Example-TestA", "UIF - "], kc=tenant.kc, connect=tenant.connect, tenants=[], out=lines.append)
        self.assertEqual(status, 0)
        self.assertFalse([c for c in tenant.calls if c[0] != "GET"])
        self.assertIn("1 object(s) named 'UIF - '", lines)

    def test_mistyped_action_is_a_usage_error(self):
        for action in ("cont", "Delete", "delete ", "", "remove"):
            with self.assertRaises(tenant_guard.Usage, msg=action):
                purge_prefix.parse_args(["Example-TestA", "UIF - ", action])

    def test_usage_error_exits_non_zero(self):
        with self.assertRaises(SystemExit) as exit:
            tenant_guard.run(lambda: purge_prefix.parse_args(["Example-TestA", "UIF - ", "cont"]))
        self.assertEqual(exit.exception.code, 2)
        with self.assertRaises(SystemExit) as exit:
            tenant_guard.run(lambda: purge_prefix.parse_args(["Example-TestA", ""]))
        self.assertEqual(exit.exception.code, 1)

    def test_delete_removes_only_prefixed_objects(self):
        tenant = FakeTenant()
        status = purge_prefix.purge(["Example-TestA", "UIF - ", "delete"], kc=tenant.kc, connect=tenant.connect, tenants=TENANTS, out=lambda _: None)
        self.assertEqual(status, 0)
        self.assertEqual([c for c in tenant.calls if c[0] == "DELETE"], [("DELETE", "/proclassic/policies/id/1")])


class AllowListTests(unittest.TestCase):
    def test_service_not_on_the_allow_list_is_refused_before_signing_in(self):
        tenant = FakeTenant()
        with self.assertRaises(tenant_guard.Refused):
            purge_prefix.purge(["Example-Unknown", "UIF - ", "delete"], kc=tenant.kc, connect=tenant.connect, tenants=TENANTS)
        self.assertEqual(tenant.calls, [])

    def test_read_only_or_production_tenant_is_refused(self):
        with self.assertRaises(tenant_guard.Refused):
            tenant_guard.require_writable("Example-ReadOnly", "jamfPlatform", "00000000-0000-4000-8000-000000000002", TENANTS)
        production = [dict(TENANTS[0], production=True)]
        with self.assertRaises(tenant_guard.Refused):
            tenant_guard.require_writable("Example-TestA", "jamfPlatform", ENVIRONMENT, production)

    def test_service_pointing_at_another_tenant_is_refused(self):
        tenant = FakeTenant(environment="00000000-0000-4000-8000-000000000099")
        with self.assertRaises(tenant_guard.Refused):
            purge_prefix.purge(["Example-TestA", "UIF - ", "delete"], kc=tenant.kc, connect=tenant.connect, tenants=TENANTS)
        self.assertEqual(tenant.calls, [])
        with self.assertRaises(tenant_guard.Refused):
            tenant_guard.require_writable("Example-TestA", "jamfPro", "other.example.com", TENANTS)

    def test_allow_listed_tenant_passes(self):
        self.assertEqual(tenant_guard.require_writable("Example-TestA", "jamfPlatform", ENVIRONMENT.upper(), TENANTS), "jamf-test-a")
        self.assertEqual(tenant_guard.require_writable("Example-TestA", "jamfPro", "https://Test-A.example.com/", TENANTS), "jamf-test-a")

    def test_allow_list_file_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "allowlist.json")
            with self.assertRaises(tenant_guard.Refused):
                tenant_guard.load_allowlist(path)  # missing
            with open(path, "w") as f:
                f.write('{"version": 1, "tenants": []}')
            os.chmod(path, 0o644)
            with self.assertRaises(tenant_guard.Refused):
                tenant_guard.load_allowlist(path)  # readable by others
            os.chmod(path, 0o600)
            self.assertEqual(tenant_guard.load_allowlist(path), [])


if __name__ == "__main__":
    unittest.main()
