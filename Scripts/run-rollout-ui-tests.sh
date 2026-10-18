#!/bin/zsh
# Runs the fleet rollout UI tests against two test tenants, then removes
# everything they created: the "Rollout UI Test" category on each tenant
# and the exported recovery sheets. The tests connect the tenants, stage a
# category on each, roll out twice and remove the tenants from the app.
#
# Credentials come from the login Keychain (generic passwords with the
# accounts base-url, client-id, client-secret and environment-id) and reach
# the test runner only as environment variables. Override the Keychain
# services with ROLLOUT_SERVICE_A / ROLLOUT_SERVICE_B. Never point this at
# a production tenant.
set -e
cd "$(dirname "$0")/.."
A="${ROLLOUT_SERVICE_A:-JamfDeployer-Spike}"
B="${ROLLOUT_SERVICE_B:-JamfDeployer-Demo}"
kc() { security find-generic-password -s "$1" -a "$2" -w }

export TEST_RUNNER_SBX_CLIENT_ID="$(kc $A client-id)"
export TEST_RUNNER_SBX_CLIENT_SECRET="$(kc $A client-secret)"
export TEST_RUNNER_SBX_ENVIRONMENT_ID="$(kc $A environment-id)"
export TEST_RUNNER_DEMO_CLIENT_ID="$(kc $B client-id)"
export TEST_RUNNER_DEMO_CLIENT_SECRET="$(kc $B client-secret)"
export TEST_RUNNER_DEMO_ENVIRONMENT_ID="$(kc $B environment-id)"

# The UI test target doesn't build the app, so build the Debug app first.
xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
set +e
xcodebuild test -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
    -only-testing:"Jamf DeployerUITests/RolloutUITests" 2>&1 | grep -E "error:|Test Case .*(passed|failed)|TEST (SUCCEEDED|FAILED)"
set -e

# Remove the test categories (the app never deletes on its own).
for service in "$A" "$B"; do
    echo "Cleaning up $service"
    BASE="$(kc $service base-url)" CID="$(kc $service client-id)" SEC="$(kc $service client-secret)" ENVID="$(kc $service environment-id)" \
    /usr/bin/python3 - <<'EOF'
import json, os, urllib.parse, urllib.request
base = os.environ["BASE"].rstrip("/")
body = urllib.parse.urlencode({"grant_type": "client_credentials",
    "client_id": os.environ["CID"], "client_secret": os.environ["SEC"]}).encode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + "/auth/token", data=body)))["access_token"]
def call(method, path):
    request = urllib.request.Request(base + path, method=method, headers={
        "Authorization": "Bearer " + token, "X-Environment-Id": os.environ["ENVID"], "Accept": "application/json"})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        return json.loads(data) if data else None
for category in call("GET", "/pro/v1/categories?page-size=2000")["results"]:
    if category["name"] == "Rollout UI Test":
        call("DELETE", "/pro/v1/categories/" + category["id"])
        print("  deleted category", category["id"])
EOF
done

# The recovery sheets hold the test tenants' state passphrases.
rm -f ~/Documents/"Jamf Deployer Recovery — Rollout Sandbox.txt" ~/Documents/"Jamf Deployer Recovery — Rollout Demo.txt"
