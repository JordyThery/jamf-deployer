#!/bin/zsh
# Runs the rename UI tests (RenameUITests) against one test tenant: a local
# catalog whose second release renames a group another block scopes to.
# Deploying that release must finish without failures; afterwards the old
# group is gone and the policy scopes to the renamed one. Everything the run
# created is removed afterwards.
#
#   Scripts/run-rename-ui-tests.sh
#
# Credentials come from the login Keychain (base-url, client-id,
# client-secret, environment-id under RENAME_SERVICE, default
# JamfDeployer-Beta) and reach the test runner only as environment
# variables. Never point this at a production tenant.
set -e
cd "$(dirname "$0")/.."
S="${RENAME_SERVICE:-JamfDeployer-Beta}"
PREFIX="UIT RN - "
kc() { security find-generic-password -s "$S" -a "$1" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-renametest.XXXXXX)"

# Calls the Jamf API: api <python statements using call(method, path)>
api() {
    BASE="$(kc base-url)" CID="$(kc client-id)" SEC="$(kc client-secret)" ENVID="$(kc environment-id)" PREFIX="$PREFIX" \
    /usr/bin/python3 -c "
import json, os, urllib.parse, urllib.request
base = os.environ['BASE'].rstrip('/'); prefix = os.environ['PREFIX']
body = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': os.environ['CID'], 'client_secret': os.environ['SEC']}).encode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + '/auth/token', data=body)))['access_token']
def call(method, path):
    request = urllib.request.Request(base + path, method=method, headers={
        'Authorization': 'Bearer ' + token, 'X-Environment-Id': os.environ['ENVID'], 'Accept': 'application/json'})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        return json.loads(data) if data else None
policies = [p for p in call('GET', '/proclassic/policies')['policies'] if p['name'].startswith(prefix)]
groups = [g for g in call('GET', '/device-groups/v1/device-groups?page-size=500')['results'] if g['name'].startswith(prefix)]
$1"
}

cleanup() {
    (( CLEANED )) && return 0
    CLEANED=1
    setopt local_options no_err_exit
    echo "Cleaning up"
    api "
for p in policies:
    call('DELETE', '/proclassic/policies/id/%s' % p['id']); print('  deleted', p['name'])
for g in groups:
    call('DELETE', '/device-groups/v1/device-groups/' + g['id']); print('  deleted', g['name'])"
    rm -f ~/Documents/"Jamf Deployer Recovery — UI Rename.txt"
    rm -rf "$WORK"
}
CLEANED=0
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# Two blocks: a static group, and a policy scoped to it through the group
# block's outputs. v1.0.1 renames the group (new address, new name, new key).
B="$WORK/work"
mkdir -p "$B/blocks/rename-groups" "$B/blocks/rename-policy"
cat > "$B/catalog.json" <<'EOF'
{ "id": "uit-rename", "name": "UI Rename Catalog", "schemaVersion": 1 }
EOF
for block in rename-groups rename-policy; do
    cat > "$B/blocks/$block/versions.tf" <<'EOF'
terraform {
  required_providers {
    jamfplatform = {
      source = "jamf/jamfplatform"
    }
  }
}
EOF
done
manifest() { # manifest <id> <name> <version> <provides-or-needs json>
    cat > "$B/blocks/$1/block.json" <<EOF
{
  "acceptsCategory": false, "alwaysOn": false, "category": "Core", "conflicts": [],
  "id": "$1", "name": "$2", "summary": "Rename test block.", "version": "$3",
  "minJamfProVersion": "11.31.0", "objectsCreated": ["1 object"],
  "permissions": [], "products": ["jamf-pro", "jamf-platform"], "requires": [],
  "risk": "low", "scope": { "kind": "none" }, "settings": [], $4
}
EOF
}
release() { # release <version> <resource name> <group name>
    manifest rename-groups "Rename Groups" "$1" "\"provides\": { \"device_group\": [\"$3\"] }"
    manifest rename-policy "Rename Policy" "$1" "\"needs\": { \"device_group\": [\"$3\"] }"
    cat > "$B/blocks/rename-groups/main.tf" <<EOF
resource "jamfplatform_device_group" "$2" {
  name        = "\${var.name_prefix}$3"
  device_type = "computer"
  group_type  = "static"
}

output "device_group_ids" {
  value = { "$3" = jamfplatform_device_group.$2.id }
}

output "device_group_names" {
  value = { "$3" = jamfplatform_device_group.$2.name }
}

output "device_group_jamf_pro_ids" {
  value = { "$3" = jamfplatform_device_group.$2.jamf_pro_id }
}
EOF
    cat > "$B/blocks/rename-policy/main.tf" <<EOF
resource "jamfplatform_pro_policy" "check" {
  general = {
    name          = "\${var.name_prefix}Rename Check"
    enabled       = false
    frequency     = "Ongoing"
    trigger_other = "uit-rename-check"
  }
  scope = {
    targets = {
      computer_group_ids = [var.dep_device_group_jamf_pro_ids["$3"]]
    }
  }
}
EOF
}
cat > "$B/blocks/rename-groups/variables.tf" <<'EOF'
variable "name_prefix" {
  type = string
}

variable "managed_by_tag" {
  type = string
}
EOF
cat > "$B/blocks/rename-policy/variables.tf" <<'EOF'
variable "name_prefix" {
  type = string
}

variable "managed_by_tag" {
  type = string
}

variable "dep_device_group_ids" {
  type    = map(string)
  default = {}
}

variable "dep_device_group_names" {
  type    = map(string)
  default = {}
}

variable "dep_device_group_jamf_pro_ids" {
  type    = map(string)
  default = {}
}
EOF
git -C "$B" init -q -b main
release 1.0.0 pilot "Rename Pilot"
git -C "$B" add -A && git -C "$B" -c user.name="UI test" -c user.email="uitest@localhost" commit -qm "v1.0.0" && git -C "$B" tag v1.0.0
release 1.0.1 pilot_renamed "Rename Pilot Renamed"
git -C "$B" add -A && git -C "$B" -c user.name="UI test" -c user.email="uitest@localhost" commit -qm "v1.0.1" && git -C "$B" tag v1.0.1
git clone -q --bare "$B" "$WORK/catalog.git"

export TEST_RUNNER_RNM_CLIENT_ID="$(kc client-id)"
export TEST_RUNNER_RNM_CLIENT_SECRET="$(kc client-secret)"
export TEST_RUNNER_RNM_ENVIRONMENT_ID="$(kc environment-id)"
export TEST_RUNNER_UITEST_CATALOG_URL="file://$WORK/catalog.git"

defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/RenameUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt): $(grep -m1 -E "Testing failed|error" "$log")"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}

set +e
for step in test1ConnectAndSetPrefix test2AddCatalog test3DeployFirstRelease test4DeployRenamingRelease; do run $step; done
echo "Checking the tenant"
api "
names = sorted(g['name'] for g in groups)
ok = names == [prefix + 'Rename Pilot Renamed']
print(('  ok   ' if ok else '  FAIL ') + 'groups: %s' % names)
detail = call('GET', '/proclassic/policies/id/%s' % policies[0]['id'])['policy'] if policies else None
scoped = [g['name'] for g in detail['scope']['computer_groups']] if detail else []
ok2 = scoped == [prefix + 'Rename Pilot Renamed']
print(('  ok   ' if ok2 else '  FAIL ') + 'policy scope: %s' % scoped)"
run test5RemoveTenantAndCatalog
set -e
