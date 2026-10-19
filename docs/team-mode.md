# Team Mode

Team Mode lets several engineers manage the same tenants from their own Macs. Tenant records are shared through a private GitHub repository. Engine state is kept in the same repository by a standard remote state backend. Solo installs already keep everything in a local Git repository, so switching over adds a remote; nothing is restructured.

## How it works

The team space repository has two parts:

- **The `main` branch** holds the app's store: tenant records, baselines, history and the list of catalog sources. Block contents travel through Git catalog sources, not the store. Engine state is never committed here.
- **The `jamf-deployer-state` branch** holds each tenant's engine state at `tenants/<id>/terraform.tfstate`. The app reads and writes it through [terraform-backend-git](https://github.com/plumber-cd/terraform-backend-git), an open-source HTTP state backend. The app starts its own copy on this Mac when needed; it listens only on the loopback address and is stopped when the app quits.

When you run an operation (preview, check for changes, deploy):

- **Before it starts**, the app pulls the store, so you work on the latest baseline.
- **The engine locks the tenant's state** for the length of the run, using the backend's standard locking: a lock is a `locks/tenants/<id>/terraform.tfstate` branch naming the engineer, the Mac and the operation. If a teammate holds the lock, your run stops and the tenant page names them, their Mac, what they're doing and since when.
- **After it finishes**, the app commits the result with a readable message ("Deploy Acme: 3 added · 1 changed · 0 removed · 0 failed — Jordy") and pushes it. The engine releases the lock.

## Encryption

State is encrypted on this Mac with OpenTofu's native state encryption (PBKDF2 + AES-GCM) before it reaches the backend. The repository never holds readable state. In Team Mode, every tenant uses one **team passphrase**:

- It is generated when the team space is created. Store it in the team's password manager; the app asks you to confirm this before it continues.
- Each engineer enters it once when joining. It is kept in that Mac's Keychain.
- **Settings → Team** shows or copies it, and accepts it on a Mac that doesn't have it yet. The tenant recovery sheet in Team Mode holds the team passphrase and the team space URL.

Without the team passphrase, nobody can read the records, including the app.

## What is and isn't in the repository

| In the repository | Never in the repository |
| --- | --- |
| Tenant records (names, selected blocks, settings, scope) | API client secrets and Jamf Pro passwords |
| Engine state, **encrypted** with the team passphrase (state branch) | The team passphrase |
| History, including a readable copy of each applied plan with every sensitive value masked | Secret-typed block settings |
| Adopted configuration, the list of catalog sources | Engineers' own client IDs and usernames |

Anyone with repository access can see tenant names, structure and encrypted state, so limit who can access the repository.

## Credentials

Credentials are never shared through the repository. Each engineer signs in to each tenant with their own API client or Jamf Pro account:

- On a Mac that doesn't have a tenant's credentials yet, use **Update Client Secret…** on the tenant page.
- In Team Mode the same sheet also takes your own **Client ID** (or **Username**). It is kept in this Mac's Keychain and overrides the one in the shared record, for this Mac only.
- Jamf's audit logs then show which engineer made each change.

## Setting up

**Create** (first engineer): open Settings and go to **Team**.
1. Enter the URL of an empty private GitHub repository under **Repository URL**, then click **Create Team Space…**.
2. Copy the team passphrase into the team's password manager, tick **I saved the team passphrase**, then click **Create Team Space**.

The app first zips a backup of the local store. It then pushes the store to `main`, creates the state branch and moves each tenant's state there. The state is re-encrypted with the team passphrase.

**Join** (everyone else): open Settings and go to **Team**.
1. Enter the repository URL and the team passphrase.
2. Click **Join Team Space…**.

What happens to this Mac's data:
- Local tenants the team space doesn't know yet are copied in, and their state moves to the state branch.
- Tenants with the same ID are skipped, never overwritten.
- The team's settings, including its list of catalog sources, replace this Mac's. A backup is kept.

**Leave**: open Settings, go to **Team** and click **Leave Team Mode…**. What happens:
- Each tenant's state is copied back to this Mac and re-encrypted with that tenant's own passphrase. Save a new recovery sheet for each tenant before its next deploy.
- This Mac keeps a full local copy with history and stops syncing.
- The team space itself is untouched.

**Removing a tenant** in Team Mode removes its record from `main` and its state from the state branch, so teammates no longer see it. The objects in Jamf are untouched.

## Force Unlock

A run that was interrupted, for example by a crash, a force quit or a lost connection, can leave its lock behind. The tenant page shows the lock with **Force Unlock…**.

Only use Force Unlock when you know the other run has stopped. Unlocking a live run lets two engineers change the tenant at once.

## Requirements and caveats

- Each Mac needs push access to the repository, with Git credentials already set up: an SSH key, or HTTPS credentials in Git's credential helper (for example after `gh auth login`). The app never asks for Git passwords. It hands those credentials only to its own state backend process.
- Locks don't expire on their own. Force Unlock is the manual way out.
- A tenant runs one engine operation at a time on a Mac (preview, check or deploy). A second request is refused with a message.
- When joining, tenants whose ID already exists in the team space are skipped, not merged.
