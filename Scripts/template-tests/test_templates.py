# Tests for the scripts Export as Terraform writes (Templates/standalone-export).
# No network, no GitHub, no Terraform: each script runs against a throwaway
# Git repository or with its Terraform calls replaced.
#   /usr/bin/python3 -I -m unittest discover -s Scripts/template-tests
import importlib.util, io, json, os, shutil, subprocess, sys, tempfile, textwrap, unittest
from unittest import mock

TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Templates", "standalone-export")


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.com",
                            GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.com"))


def read(path):
    with open(path) as f:
        return f.read()


def write(repo, path, text="x\n"):
    full = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)


def fixture_repo():
    """tenants/alpha, tenants/beta, tenants/_template and a module, committed."""
    repo = tempfile.mkdtemp(prefix="template-test-")
    git(repo, "init", "-q", "-b", "main")
    for path in ("tenants/alpha/main.tf", "tenants/beta/main.tf", "tenants/_template/main.tf", "modules/block/main.tf"):
        write(repo, path)
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "start")
    return repo


class DetectTenantsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("jq"):
            raise unittest.SkipTest("jq isn’t installed")
        text = read(os.path.join(TEMPLATE, ".github", "actions", "detect-tenants", "action.yml"))
        script = text.split("run: |\n", 1)[1]
        cls.script = textwrap.dedent(script)

    def run_action(self, repo, base="", all_tenants="false"):
        output = os.path.join(repo, ".github-output")
        open(output, "w").close()
        subprocess.run(["bash", "-c", self.script], cwd=repo, check=True, capture_output=True,
                       env=dict(os.environ, BASE=base, ALL=all_tenants, GITHUB_OUTPUT=output))
        line = [l for l in read(output).splitlines() if l.startswith("tenants=")][-1]
        return json.loads(line.split("=", 1)[1])

    def setUp(self):
        self.repo = fixture_repo()
        self.base = subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def commit(self, path):
        write(self.repo, path, "changed\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "change")

    def test_a_tenant_change_lists_that_tenant(self):
        self.commit("tenants/alpha/main.tf")
        self.assertEqual(self.run_action(self.repo, base=self.base), ["alpha"])

    def test_a_module_change_lists_every_tenant(self):
        self.commit("modules/block/main.tf")
        self.assertEqual(self.run_action(self.repo, base=self.base), ["alpha", "beta"])

    def test_the_template_is_never_a_tenant(self):
        self.commit("tenants/_template/main.tf")
        self.assertEqual(self.run_action(self.repo, base=self.base), [])
        self.assertEqual(self.run_action(self.repo, all_tenants="true"), ["alpha", "beta"])

    def test_a_first_push_or_unknown_base_lists_every_tenant(self):
        self.assertEqual(self.run_action(self.repo, base="0000000000000000000000000000000000000000"), ["alpha", "beta"])
        self.assertEqual(self.run_action(self.repo, base="1234567"), ["alpha", "beta"])

    def test_names_outside_the_pattern_are_skipped(self):
        self.commit("tenants/Bad Name/main.tf")
        self.assertEqual(self.run_action(self.repo, base=self.base), [])


class NewTenantTests(unittest.TestCase):
    """The checks new-tenant.sh makes before it touches GitHub."""
    def setUp(self):
        self.repo = fixture_repo()
        os.makedirs(os.path.join(self.repo, "scripts"))
        shutil.copy(os.path.join(TEMPLATE, "scripts", "new-tenant.sh"), os.path.join(self.repo, "scripts"))
        # A gh that fails the test if it's ever called.
        self.bin = tempfile.mkdtemp(prefix="template-bin-")
        with open(os.path.join(self.bin, "gh"), "w") as f:
            f.write("#!/bin/sh\necho gh was called >&2\nexit 99\n")
        os.chmod(os.path.join(self.bin, "gh"), 0o755)

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)
        shutil.rmtree(self.bin, ignore_errors=True)

    def run_script(self, name):
        return subprocess.run(["sh", "scripts/new-tenant.sh", name], cwd=self.repo, capture_output=True, text=True,
                              env=dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"]))

    def test_refuses_names_outside_the_pattern(self):
        for name in ("Contoso", "-leading", "has space", "../escape"):
            result = self.run_script(name)
            self.assertEqual(result.returncode, 1, name)
            self.assertIn("lower case letters", result.stderr)
            self.assertNotIn("gh was called", result.stderr)

    def test_refuses_an_existing_tenant(self):
        result = self.run_script("alpha")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tenants/alpha already exists", result.stderr)
        self.assertNotIn("gh was called", result.stderr)


class NotInCodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = os.path.join(TEMPLATE, ".github", "scripts", "not_in_code.py")
        spec = importlib.util.spec_from_file_location("not_in_code", path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="not-in-code-")
        self.cwd = os.getcwd()
        os.chdir(self.folder)

    def tearDown(self):
        os.chdir(self.cwd)
        shutil.rmtree(self.folder, ignore_errors=True)

    def fake_terraform(self, generated):
        state = {"values": {"root_module": {"child_modules": [{"resources": [
            {"mode": "managed", "type": "jamfplatform_pro_category", "values": {"id": "1"}},
            {"mode": "data", "type": "jamfplatform_pro_script", "values": {"id": "9"}},
        ]}]}}}
        schema = {"provider_schemas": {"registry.terraform.io/jamf/jamfplatform": {
            "list_resource_schemas": {"jamfplatform_pro_category": {}, "jamfplatform_device_group": {}}}}}
        found = [
            {"list_resource_found": {"resource_type": "jamfplatform_pro_category", "display_name": "Managed", "identity": {"id": "1"}}},
            {"list_resource_found": {"resource_type": "jamfplatform_pro_category", "display_name": "Hand Made", "identity": {"id": "2"}}},
            {"list_resource_found": {"resource_type": "jamfplatform_pro_category", "display_name": "Ignored", "identity": {"id": "3"}}},
        ]

        def terraform(*args):
            if args[:2] == ("show", "-json"):
                return json.dumps(state)
            if args[:2] == ("providers", "schema"):
                return json.dumps(schema)
            if args[0] == "query" and "-json" in args:
                return "\n".join(json.dumps(event) for event in found)
            if args[0] == "query":
                path = [a for a in args if a.startswith("-generate-config-out=")][0].split("=", 1)[1]
                with open(path, "w") as f:
                    f.write(generated)
                return ""
            raise AssertionError(args)
        return terraform

    def test_reports_only_unmanaged_objects_that_arent_ignored(self):
        generated = textwrap.dedent('''\
            resource "jamfplatform_pro_category" "all_2" {
              name     = "Hand Made"
              priority = null
            }
            import {
              to = jamfplatform_pro_category.all_2
              id = "2"
            }
            resource "jamfplatform_pro_category" "all_3" {
              name = "Ignored"
            }
            import {
              to = jamfplatform_pro_category.all_3
              id = "3"
            }
            ''')
        with open("not-in-code.ignore", "w") as f:
            f.write("# left alone on purpose\njamfplatform_pro_category 3   # Ignored\n")
        output = os.path.join(self.folder, "github-output")
        fmt = mock.Mock(return_value=subprocess.CompletedProcess([], 1, stdout="", stderr=""))
        with mock.patch.dict(os.environ, {"RUNNER_TEMP": self.folder, "GITHUB_OUTPUT": output}), \
             mock.patch.object(self.module, "terraform", self.fake_terraform(generated)), \
             mock.patch.object(self.module.subprocess, "run", fmt):
            self.module.main()
        self.assertIn("found=1", read(output))
        report = read(os.path.join(self.folder, "not-in-code.md"))
        self.assertIn("| `jamfplatform_pro_category` | 2 | Hand Made |", report)
        self.assertNotIn("| 1 |", report)
        self.assertNotIn("Ignored |", report)
        # The configuration to paste renames the object after itself and
        # drops null attributes.
        self.assertIn('resource "jamfplatform_pro_category" "hand_made"', report)
        self.assertNotIn("= null", report)
        self.assertIn('identity = { id = "2" }', report)
        self.assertFalse(os.path.exists("not-in-code.tfquery.hcl"))

    def test_long_reports_are_cut_for_the_issue(self):
        report = os.path.join(self.folder, "not-in-code.md")
        self.module.ISSUE_LIMIT = 200
        try:
            many = [{"list_resource_found": {"resource_type": "jamfplatform_pro_category",
                                             "display_name": f"Object {n}", "identity": {"id": str(10 + n)}}} for n in range(40)]
            terraform = self.fake_terraform("")

            def with_many(*args):
                if args[0] == "query" and "-json" in args:
                    return "\n".join(json.dumps(event) for event in many)
                return terraform(*args)
            output = os.path.join(self.folder, "github-output")
            fmt = mock.Mock(return_value=subprocess.CompletedProcess([], 0, stdout="\n", stderr=""))
            with mock.patch.dict(os.environ, {"RUNNER_TEMP": self.folder, "GITHUB_OUTPUT": output}), \
                 mock.patch.object(self.module, "terraform", with_many), \
                 mock.patch.object(self.module.subprocess, "run", fmt):
                self.module.main()
        finally:
            self.module.ISSUE_LIMIT = 60000
        issue = read(os.path.join(self.folder, "not-in-code-issue.md"))
        self.assertLess(len(issue), len(read(report)))
        self.assertIn("longer than an issue can hold", issue)
        self.assertEqual(issue.count("```") % 2, 0)


if __name__ == "__main__":
    unittest.main()
