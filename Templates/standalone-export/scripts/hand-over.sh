#!/bin/sh
# Stops managing a tenant without deleting anything in Jamf: opens a pull
# request that removes tenants/<name>. When it is merged, the Apply workflow
# moves the tenant's state to handed-over/ on the terraform-state branch, so
# the objects stay in Jamf exactly as they are and nothing plans against them
# again. To delete the objects instead, run the Destroy workflow first.
#
#   scripts/hand-over.sh <name>
#
# Needs git and the GitHub CLI (gh), signed in with access to this repository.
set -eu
NAME="${1:?usage: scripts/hand-over.sh <name>}"
die() { echo "$1" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"
echo "$NAME" | grep -Eq '^[a-z0-9][a-z0-9-]*$' && [ "$NAME" != _template ] && [ -d "tenants/$NAME" ] \
  || die "No tenant named $NAME under tenants/."
command -v gh > /dev/null || die "Install the GitHub CLI first: https://cli.github.com"
BRANCH="hand-over/$NAME"
if git rev-parse -q --verify "refs/heads/$BRANCH" > /dev/null || git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null; then
  die "The branch $BRANCH already exists from an earlier attempt; delete it (git branch -D $BRANCH; git push origin --delete $BRANCH) and run this again."
fi
printf 'Type %s again to hand it over: ' "$NAME"
read -r confirm
[ "$confirm" = "$NAME" ] || die "Not confirmed; nothing changed."

git fetch -q origin main
git switch -q -c "$BRANCH" origin/main
git rm -q -r "tenants/$NAME"
git commit -q -m "Hand over $NAME"
git push -q -u origin "$BRANCH"
gh pr create --base main --head "$BRANCH" --title "Hand over $NAME" \
  --body "Stops managing \`$NAME\` from this repository. Its objects stay in Jamf; after merging, its state moves to \`handed-over/\` on the \`terraform-state\` branch. Afterwards, delete its Environments ($NAME and $NAME-plan) under Settings → Environments."
