#!/bin/zsh
# Runs the Team Mode UI tests (TeamModeUITests) against a test tenant and a
# private test repository: create a team space, check and restore through
# the state backend, a teammate's lock and force-unlock, leave, join again,
# and remove the tenant from the team space.
#
#   Scripts/run-team-ui-tests.sh <owner/repository>
#
# The repository must be a private test repository you can push to: its
# main and state branches are replaced (the old main is parked on a branch).
# This Mac's store is set aside for the run and put back afterwards.
# Credentials come from the login Keychain (base-url, client-id,
# client-secret, environment-id and jamfpro-* under ROLLOUT_SERVICE_A,
# default JamfDeployer-Spike) and reach the test runner only as environment
# variables. Never point this at a production tenant.
set -e
cd "$(dirname "$0")/.."
REPO="$1"
A="${ROLLOUT_SERVICE_A:-JamfDeployer-Spike}"
kc() { security find-generic-password -s "$1" -a "$2" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-teamtest.XXXXXX)"
chmod 700 "$WORK"
SUPPORT="$HOME/Library/Application Support/Jamf Deployer"
STAMP="$(date +%Y%m%d-%H%M%S)"
HELPERS="$(dirname "$0")/catalog-test"

export TEST_RUNNER_SBX_CLIENT_ID="$(kc $A client-id)"
export TEST_RUNNER_SBX_CLIENT_SECRET="$(kc $A client-secret)"
export TEST_RUNNER_SBX_ENVIRONMENT_ID="$(kc $A environment-id)"
export TEST_RUNNER_TEAM_REPOSITORY="https://github.com/$REPO.git"

rm -f ~/Documents/"Jamf Deployer Recovery — Team Sandbox.txt"
# This Mac's store is set aside; the run starts with an empty one.
pkill -x "Jamf Deployer" 2>/dev/null || true
mv "$SUPPORT/store" "$SUPPORT/store-set-aside-$STAMP"
# Puts this Mac's store and the repository back. Runs at the end, and from
# the trap when the script is interrupted.
restore_store() {
    [[ -d "$SUPPORT/store-set-aside-$STAMP" ]] || return 0
    pkill -x "Jamf Deployer" 2>/dev/null
    sleep 2
    rm -rf "$SUPPORT/store" "$SUPPORT/store-replaced" "$SUPPORT/store-joining"
    mv "$SUPPORT/store-set-aside-$STAMP" "$SUPPORT/store"
    rm -f "$SUPPORT"/store-backup-*.zip(N)
    local parked
    parked="$(gh api "repos/$REPO/git/refs/heads/uitest-parking" --jq .object.sha 2>/dev/null)"
    if [[ -n "$parked" ]]; then
        gh api -X DELETE "repos/$REPO/git/refs/heads/main" > /dev/null 2>&1
        gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/main -f sha="$parked" > /dev/null 2>&1
        gh api -X PATCH "repos/$REPO" -f default_branch=main > /dev/null 2>&1
    fi
    for branch in $(gh api "repos/$REPO/branches" --jq '.[].name' 2>/dev/null | grep -v '^main$'); do
        gh api -X DELETE "repos/$REPO/git/refs/heads/$branch" > /dev/null 2>&1
    done
    rm -f ~/Documents/"Jamf Deployer Recovery — Team Sandbox.txt"
    # Step logs are kept for diagnosis, without the passphrase.
    mkdir -p /tmp/jamf-deployer-team-logs
    for log in "$WORK"/*.log(N); do
        sed -E 's/TEAM-PASSPHRASE: .*/TEAM-PASSPHRASE: (redacted)/' "$log" > "/tmp/jamf-deployer-team-logs/${log:t}"
    done
    rm -rf "$WORK"
    echo "Store and repository restored"
}
trap restore_store EXIT INT TERM

# The repository starts without main and state branches.
SHA="$(gh api "repos/$REPO/git/refs/heads/main" --jq .object.sha 2>/dev/null || true)"
if [[ -n "$SHA" ]]; then
    gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/uitest-parking -f sha="$SHA" > /dev/null
    gh api -X PATCH "repos/$REPO" -f default_branch=uitest-parking > /dev/null
    gh api -X DELETE "repos/$REPO/git/refs/heads/main" > /dev/null
fi
gh api -X DELETE "repos/$REPO/git/refs/heads/jamf-deployer-state" > /dev/null 2>&1 || true

xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/TeamModeUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt)"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}
tenant_id() {
    /usr/bin/python3 -c "
import json, glob
for p in glob.glob('$SUPPORT/store/tenants/*/tenant.json'):
    if json.load(open(p))['name'] == 'Team Sandbox': print(p.split('/')[-2])"
}
branch_files() { gh api "repos/$REPO/git/trees/$1?recursive=1" --jq '.tree[].path' 2>/dev/null; }
category() { # category <python statements>, through the Jamf Pro API
    /usr/bin/python3 "$HELPERS/jpcall.py" "$A" "c = next(x for x in call('GET', '/api/v1/categories?page-size=2000')['results'] if x['name'] == 'UIT - Team Category'); $1"
}

set +e
run test01ConnectAndDeploy
run test02CreateTeamSpace
ID="$(tenant_id)"
echo "Repository after creating the team space:"
echo "  main has the tenant record: $(branch_files main | grep -c "tenants/$ID/tenant.json")"
echo "  main has state files: $(branch_files main | grep -c 'state/')"
echo "  state branch has the record: $(branch_files jamf-deployer-state | grep -c "tenants/$ID/terraform.tfstate")"
STATE="$(gh api "repos/$REPO/contents/tenants/$ID/terraform.tfstate?ref=jamf-deployer-state" --jq .content | base64 -d)"
echo "  state is encrypted: $(print -r -- "$STATE" | grep -c encrypted_data), plain names in it: $(print -r -- "$STATE" | grep -c 'UIT - Team Category')"
echo "  local state left in the workspace: $(ls "$SUPPORT/store/tenants/$ID/state/terraform.tfstate" 2>/dev/null | wc -l | tr -d ' ')"
run test03CheckThroughTheTeamSpace
category "call('PUT', '/api/v1/categories/' + c['id'], {'name': c['name'], 'priority': 3}); print('  changed the category in Jamf')"
run test04DetectAndRestore

# The teammate: their own state backend, holding this tenant's lock.
PORT=$(( 40000 + RANDOM % 20000 )); PASS="$(uuidgen)"
mkdir -p "$WORK/teammate"
TMPDIR="$WORK/teammate" GIT_USERNAME=x-access-token GITHUB_TOKEN="$(gh auth token)" TF_BACKEND_GIT_HTTP_USERNAME=mate TF_BACKEND_GIT_HTTP_PASSWORD="$PASS" \
    Vendor/terraform-backend-git/terraform-backend-git --address=127.0.0.1:$PORT > "$WORK/teammate.log" 2>&1 &
MATE=$!
sleep 2
U="http://127.0.0.1:$PORT/?type=git&repository=https://github.com/$REPO.git&ref=jamf-deployer-state&state=tenants/$ID/terraform.tfstate"
echo "  teammate locks the tenant: $(curl -s -o /dev/null -w '%{http_code}' -u mate:$PASS -X LOCK \
    --data '{"ID":"teammate-lock","Operation":"OperationTypePlan","Who":"teammate@other-mac","Version":"1.13.1","Created":"2026-10-19T08:00:00Z","Path":"","Info":""}' "$U")"
kill $MATE
run test05LockedByATeammate
echo "  lock branches left: $(gh api "repos/$REPO/branches" --jq '.[].name' | grep -c '^locks/')"
run test06LeaveTeamMode
echo "  local state back in the workspace: $(ls "$SUPPORT/store/tenants/$ID/state/terraform.tfstate" 2>/dev/null | wc -l | tr -d ' ')"
export TEST_RUNNER_TEAM_PASSPHRASE="$(grep -m1 -o 'TEAM-PASSPHRASE: [^ ]*' "$WORK/test02CreateTeamSpace.log" | cut -d' ' -f2)"
run test07JoinTeamSpace
run test08RemoveTenantFromTeamSpace
echo "  record left on main: $(branch_files main | grep -c "tenants/$ID/")"
echo "  state left on the state branch: $(branch_files jamf-deployer-state | grep -c "tenants/$ID/")"
run test09LeaveEmptyTeamSpace

echo "Cleaning up"
/usr/bin/python3 "$HELPERS/jpcall.py" "$A" "
for c in call('GET', '/api/v1/categories?page-size=2000')['results']:
    if c['name'].startswith('UIT - Team'):
        call('DELETE', '/api/v1/categories/' + c['id']); print('  deleted', c['name'])"
restore_store
trap - EXIT INT TERM
