"""Lists objects in a Jamf tenant that this repository does not manage.

Run by .github/workflows/reconcile.yml from a tenant's directory, after
`terraform init`. It asks Terraform which object types the jamfplatform
plugin can list, keeps the types this tenant's code manages, lists them with
`terraform query`, and compares what Jamf has with the state.

Output: a Markdown report in $RUNNER_TEMP/not-in-code.md, the same report cut
to fit a GitHub issue in $RUNNER_TEMP/not-in-code-issue.md, and
`found=<count>` in $GITHUB_OUTPUT. Objects listed in not-in-code.ignore are skipped (one per
line: `<resource type> <id or name>`; `#` starts a comment).
"""
import json
import os
import re
import subprocess
import sys

QUERY_FILE = "not-in-code.tfquery.hcl"
IGNORE_FILE = "not-in-code.ignore"
# GitHub caps issue bodies and comments at 65,536 characters.
ISSUE_LIMIT = 60000
# Objects every Jamf Pro instance comes with.
BUILT_IN = {
    "All Managed Clients", "All Managed Servers", "All Managed iPads", "All Managed iPhones",
    "All Managed iPod touches", "All Managed Apple TVs", "All Managed Watches", "All Managed Vision Pros",
}


def terraform(*args):
    return subprocess.run(["terraform", *args], check=True, capture_output=True, text=True).stdout


def managed_ids():
    """Resource type -> IDs the state manages, across every module."""
    state = json.loads(terraform("show", "-json") or "{}")
    ids = {}

    def walk(module):
        for resource in module.get("resources", []):
            if resource.get("mode") == "managed":
                ids.setdefault(resource["type"], set()).add(str(resource.get("values", {}).get("id", "")))
        for child in module.get("child_modules", []):
            walk(child)

    walk(state.get("values", {}).get("root_module", {}))
    return ids


def listable_types():
    schema = json.loads(terraform("providers", "schema", "-json"))
    for address, provider in schema.get("provider_schemas", {}).items():
        if address.endswith("/jamf/jamfplatform"):
            return set(provider.get("list_resource_schemas", {}))
    return set()


def ignored():
    entries = set()
    if os.path.exists(IGNORE_FILE):
        for line in open(IGNORE_FILE):
            line = line.split("#", 1)[0].strip()
            if " " in line:
                kind, value = line.split(" ", 1)
                entries.add((kind, value.strip()))
    return entries


def resource_name(display_name, taken):
    name = re.sub(r"[^a-z0-9]+", "_", display_name.lower()).strip("_") or "object"
    if name[0].isdigit():
        name = "_" + name
    base, number = name, 2
    while name in taken:
        name, number = f"{base}_{number}", number + 1
    taken.add(name)
    return name


def configuration(generated, found):
    """The generated resource and import blocks of the unmanaged objects only,
    renamed after the objects."""
    wanted = {(kind, object_id): resource for kind, object_id, _, resource in found}
    blocks = re.split(r"\n(?=# __generated__|resource \"|import \{)", generated)
    resources, imports = {}, {}
    for block in blocks:
        head = re.match(r'resource "([a-z0-9_]+)" "([a-z0-9_]+)"', block)
        if head:
            resources[(head.group(1), head.group(2))] = block.strip()
        target = re.search(r"to\s*=\s*([a-z0-9_]+)\.([a-z0-9_]+)", block)
        identity = re.search(r'id\s*=\s*"([^"]+)"', block)
        if block.startswith("import") and target and identity:
            imports[(target.group(1), target.group(2))] = identity.group(1)
    text = []
    for (kind, name), object_id in imports.items():
        resource = wanted.get((kind, object_id))
        if not resource or (kind, name) not in resources:
            continue
        body = resources[(kind, name)].replace(f'"{kind}" "{name}"', f'"{kind}" "{resource}"', 1)
        body = "\n".join(line for line in body.splitlines() if not line.endswith("= null"))
        text.append(body)
        text.append(f'import {{\n  to       = {kind}.{resource}\n  identity = {{ id = "{object_id}" }}\n}}')
    hcl = "\n\n".join(text) + "\n"
    # Dropping null attributes leaves the alignment off; terraform fmt puts it
    # back, so the pasted file passes the Plan workflow's format check.
    formatted = subprocess.run(["terraform", "fmt", "-"], input=hcl, capture_output=True, text=True)
    return formatted.stdout if formatted.returncode == 0 else hcl


def main():
    managed = managed_ids()
    types = sorted(set(managed) & listable_types())
    report = os.path.join(os.environ.get("RUNNER_TEMP", "."), "not-in-code.md")
    if not types:
        open(report, "w").write("Nothing to compare: this tenant's code manages no listable object types.\n")
        print("found=0", file=open(os.environ["GITHUB_OUTPUT"], "a"))
        return

    with open(QUERY_FILE, "w") as query:
        for kind in types:
            query.write(f'list "{kind}" "all" {{\n  provider = jamfplatform\n}}\n\n')
    events = terraform("query", "-json", "-no-color")
    generated_path = os.path.join(os.environ.get("RUNNER_TEMP", "."), "not-in-code-generated.tf")
    if os.path.exists(generated_path):
        os.remove(generated_path)
    terraform("query", "-no-color", f"-generate-config-out={generated_path}")
    generated = open(generated_path).read() if os.path.exists(generated_path) else ""
    os.remove(QUERY_FILE)

    skip = ignored()
    found, taken = [], set()
    for line in events.splitlines():
        event = json.loads(line)
        item = event.get("list_resource_found")
        if not item:
            continue
        kind, name = item["resource_type"], item.get("display_name", "")
        object_id = str(item.get("identity", {}).get("id", ""))
        if object_id in managed.get(kind, set()) or name in BUILT_IN:
            continue
        if (kind, object_id) in skip or (kind, name) in skip:
            continue
        found.append((kind, object_id, name, resource_name(name, taken)))

    with open(report, "w") as out:
        if not found:
            out.write("Every listed object is managed by this repository.\n")
        else:
            out.write("| Type | ID | Name |\n| --- | --- | --- |\n")
            for kind, object_id, name, _ in found:
                out.write(f"| `{kind}` | {object_id} | {name} |\n")
            out.write("\n**To manage them here:** add this configuration to a new file in the tenant's directory\n"
                      "(for example `imported.tf`) in a pull request. Its plan shows each object as an import,\n"
                      "not a create, and merging records them; Jamf does not change. Tidy the values, or move\n"
                      "them into a module, whenever you like: a plan with no changes means they still match.\n\n```hcl\n")
            out.write(configuration(generated, found))
            out.write("```\n\n**To leave one alone:** add a line to `not-in-code.ignore` in the tenant's directory:\n\n```\n")
            for kind, object_id, name, _ in found:
                out.write(f"{kind} {object_id}   # {name}\n")
            out.write("```\n")
    full = open(report).read()
    with open(os.path.join(os.path.dirname(report), "not-in-code-issue.md"), "w") as issue:
        if len(full) <= ISSUE_LIMIT:
            issue.write(full)
        else:
            cut = full[:ISSUE_LIMIT].rsplit("\n", 1)[0]
            if cut.count("```") % 2:
                cut += "\n```"
            issue.write(cut + "\n\n**The report is longer than an issue can hold.** The full report, with the "
                        "configuration of every object, is attached to this workflow run as the "
                        "`not-in-code-<tenant>` artifact.\n")
    print(f"found={len(found)}", file=open(os.environ["GITHUB_OUTPUT"], "a"))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.stderr or "")
        raise
