#!/usr/bin/env python3
"""Prototype: turn a Jamf Deployer tenant workspace into a plain Terraform
repository layout (modules/ + tenants/<name>/). Usage:
  export_tenant.py <generated-dir> <out-repo> <tenant-slug>
"""
import os, re, shutil, sys

gen, out, slug = sys.argv[1:4]
main = open(os.path.join(gen, "main.tf")).read()
providers = open(os.path.join(gen, "providers.tf")).read()

# --- Parse the generated root module (regular, generator-controlled format).
modules = []      # (name, [(key, raw_value)])
for m in re.finditer(r'module "([a-z0-9_]+)" \{\n(.*?)\n\}', main, re.S):
    attrs = []
    for line in m.group(2).splitlines():
        k, _, v = line.strip().partition("=")
        attrs.append((k.strip(), v.strip()))
    modules.append((m.group(1), attrs))
prefix_default = re.search(r'variable "name_prefix" \{.*?default\s*=\s*(".*?")', main, re.S).group(1)

def is_literal(v):
    return v.startswith('"') or v in ("true", "false") or re.fullmatch(r"-?\d+(\.\d+)?", v) is not None

def hcl_type(v):
    if v in ("true", "false"): return "bool"
    if v.startswith('"'): return "string"
    return "number"

# --- modules/: each block whole, as the catalog ships it (minus the app's
# block.json): the Jamf Platform API module at its root, the Jamf Pro API
# module in jamfpro/, shared files beside them. A fleet mixing connections
# shares one folder per block; each tenant points at the variant it uses.
def block_of(source):                                  # ./modules/<id>[/jamfpro]
    parts = source.strip('"').split("/")
    return parts[2], len(parts) > 3 and parts[3] == "jamfpro"

os.makedirs(os.path.join(out, "modules"), exist_ok=True)
for name, attrs in modules:
    block_id, _ = block_of(dict(attrs)["source"])
    dest = os.path.join(out, "modules", block_id)
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(os.path.join(gen, "modules", block_id), dest,
                    ignore=shutil.ignore_patterns("block.json"))

# --- tenants/<slug>/
tdir = os.path.join(out, "tenants", slug)
os.makedirs(tdir, exist_ok=True)

variables, calls, tfvars = [], [], []
variables.append('variable "name_prefix" {\n  description = "Prefix applied to every object name."\n  type        = string\n}\n')
tfvars.append(f"name_prefix = {prefix_default}\n")
for name, attrs in modules:
    literals = [(k, v) for k, v in attrs if k not in ("source", "name_prefix") and is_literal(v)]
    fields = "\n".join(f"    {k} = {hcl_type(v)}" for k, v in literals)
    variables.append(f'variable "{name}" {{\n  description = "Settings for the {name} block."\n  type = object({{\n{fields}\n  }})\n}}\n')
    width = max(len(k) for k, _ in literals)
    tfvars.append(f"{name} = {{\n" + "\n".join(f"  {k.ljust(width)} = {v}" for k, v in literals) + "\n}\n")
    lines = []
    for k, v in attrs:
        if k == "source":
            block_id, jamfpro = block_of(v)
            lines.append(f'  source = "../../modules/{block_id}{"/jamfpro" if jamfpro else ""}"')
        elif k == "name_prefix":
            lines.append("  name_prefix = var.name_prefix")
        elif is_literal(v):
            lines.append(f"  {k} = var.{name}.{k}")
        else:
            lines.append(f"  {k} = {v}")     # wiring between blocks stays in code
    calls.append(f'module "{name}" {{\n' + "\n".join(lines) + "\n}\n")

open(os.path.join(tdir, "variables.tf"), "w").write(
    "# Inputs for this tenant. Values live in tenant.auto.tfvars.\n\n" + "\n".join(variables))
open(os.path.join(tdir, "main.tf"), "w").write(
    "# This tenant's baseline: one module call per building block, and how\n"
    "# the blocks connect. Setting values live in tenant.auto.tfvars.\n\n" + "\n".join(calls))
open(os.path.join(tdir, "tenant.auto.tfvars"), "w").write(
    "# The only file that differs in substance between tenants. No secrets:\n"
    "# credentials arrive as environment variables at run time.\n\n" + "\n".join(tfvars))

req = re.search(r"required_providers \{.*?\n  \}", providers, re.S).group(0)
open(os.path.join(tdir, "terraform.tf"), "w").write(f'''terraform {{
  required_version = ">= 1.11.0"

  {req}

  # Replace with your team's backend: one state object per tenant, with
  # locking. For example, S3 with key = "tenants/{slug}/terraform.tfstate",
  # encrypt = true and use_lockfile = true.
  backend "local" {{
    path = "terraform.tfstate"
  }}
}}
''')
# Everything after the terraform block: the provider blocks and their notes.
end = re.search(r"^terraform \{.*?^\}\n", providers, re.S | re.M).end()
prov = providers[end:]
open(os.path.join(tdir, "providers.tf"), "w").write(prov.strip() + "\n")
print(f"exported {len(modules)} blocks to {out}")
