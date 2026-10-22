#!/bin/sh
# Adds a tenant to this repository:
#   1. copies tenants/_template to tenants/<name>;
#   2. creates its two GitHub Environments: <name>, which only main may use,
#      and <name>-plan for pull request plans (secrets are asked for with
#      typing hidden and go straight to GitHub);
#   3. lets you edit its settings, then opens a pull request. The plan on the
#      pull request shows everything the tenant would get; nothing is created
#      in Jamf until it is reviewed and merged.
#
#   scripts/new-tenant.sh <name>      (lower case letters, digits and hyphens)
#
# Needs git and the GitHub CLI (gh), signed in with access to this repository.
set -eu
NAME="${1:?usage: scripts/new-tenant.sh <name>}"
die() { echo "$1" >&2; exit 1; }
echo "$NAME" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || die "Use lower case letters, digits and hyphens, like contoso-production."
cd "$(git rev-parse --show-toplevel)"
[ -d tenants/_template ] || die "tenants/_template is missing."
[ ! -e "tenants/$NAME" ] || die "tenants/$NAME already exists."
command -v gh > /dev/null || die "Install the GitHub CLI first: https://cli.github.com"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
# Checked before anything is created on GitHub, so a rerun starts clean.
BRANCH="new-tenant/$NAME"
if git rev-parse -q --verify "refs/heads/$BRANCH" > /dev/null || git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null; then
  die "The branch $BRANCH already exists from an earlier attempt; delete it (git branch -D $BRANCH; git push origin --delete $BRANCH) and run this again."
fi
trap 'stty echo 2> /dev/null || true' EXIT INT TERM

ask() { printf '%s: ' "$1" >&2; read -r value; [ -n "$value" ] || value="${2:-}"; printf '%s' "$value"; }
hidden() { printf '%s: ' "$1" >&2; stty -echo 2> /dev/null || true; read -r value || value=; stty echo 2> /dev/null || true; printf '\n' >&2; printf '%s' "$value"; }
environment() {
  printf '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
    | gh api -X PUT "repos/$REPO/environments/$NAME" --input - --silent
  gh api -X POST "repos/$REPO/environments/$NAME/deployment-branch-policies" -f name=main --silent 2> /dev/null || true
  gh api -X PUT "repos/$REPO/environments/$NAME-plan" --silent
}
variable() {
  gh variable set "$1" --repo "$REPO" --env "$NAME" --body "$2"
  gh variable set "$1" --repo "$REPO" --env "$NAME-plan" --body "$2"
}
secret() {
  value="$(hidden "$1")"
  printf '%s' "$value" | gh secret set "$1" --repo "$REPO" --env "$NAME"
  plan="$(hidden "$1 for plans (Return: the same; a read-only client is safer)")"
  printf '%s' "${plan:-$value}" | gh secret set "$1" --repo "$REPO" --env "$NAME-plan"
}

echo "Creating the Environments for $NAME in $REPO."
environment
if grep -q '"deploymenttheory/jamfpro"' tenants/_template/terraform.tf; then
  variable JAMFPRO_INSTANCE_FQDN "$(ask 'Jamf Pro URL (https://yourorg.jamfcloud.com)')"
  method="$(ask 'Sign in with an API client (oauth2) or a user account (basic) [oauth2]' oauth2)"
  variable JAMFPRO_AUTH_METHOD "$method"
  variable PARALLELISM 1
  if [ "$method" = basic ]; then secret JAMFPRO_BASIC_USERNAME; secret JAMFPRO_BASIC_PASSWORD
  else secret JAMFPRO_CLIENT_ID; secret JAMFPRO_CLIENT_SECRET; fi
else
  variable JAMFPLATFORM_BASE_URL "$(ask 'Jamf Platform API URL [https://us.api.jamfcloud.com]' https://us.api.jamfcloud.com)"
  variable JAMFPLATFORM_ENVIRONMENT_ID "$(ask 'Platform environment ID')"
  secret JAMFPLATFORM_CLIENT_ID
  secret JAMFPLATFORM_CLIENT_SECRET
fi
if grep -q '"Jamf-Concepts/jamfprotect"' tenants/_template/terraform.tf; then
  variable JAMFPROTECT_URL "$(ask 'Jamf Protect URL (https://yourorg.protect.jamfcloud.com)')"
  secret JAMFPROTECT_CLIENT_ID
  secret JAMFPROTECT_CLIENT_SECRET
fi
for name in $(grep -ho 'variable "[a-z0-9_]*"' tenants/_template/variables.tf | cut -d'"' -f2); do
  if grep -A4 "variable \"$name\"" tenants/_template/variables.tf | grep -q 'sensitive *= *true'; then
    secret "TF_VAR_$(echo "$name" | tr '[:lower:]' '[:upper:]')"
  fi
done

git fetch -q origin main
git switch -q -c "$BRANCH" origin/main
cp -R tenants/_template "tenants/$NAME"
echo
echo "tenants/$NAME is ready. Set its values in tenants/$NAME/tenant.auto.tfvars"
echo "(they start as copies of the template's), and remove any block it should"
echo "not get from tenants/$NAME/main.tf. Press Return when done."
read -r _
git add "tenants/$NAME"
git commit -q -m "Add tenant $NAME"
git push -q -u origin "$BRANCH"
gh pr create --base main --head "$BRANCH" --title "Add tenant $NAME" \
  --body "Adds the tenant \`$NAME\`. Its plan below shows everything it would get; nothing is created in Jamf until this is merged."
