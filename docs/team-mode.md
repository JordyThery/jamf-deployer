# Team Mode

Team Mode lets several engineers manage the same tenants from their own Macs, synchronized through a GitHub repository. Solo installs already keep everything in a local Git repository, so switching over is a remote away — nothing is restructured.

## How it works

The app's store — tenant records, encrypted state, history, catalogs, presets — is one Git repository. In Team Mode that repository has a remote on GitHub:

- **Before a tenant operation** (preview, deploy, drift check) the app pulls, takes a lock on the tenant, and works on the fresh copy.
- **After the operation** it commits the result with a readable message ("Deploy Acme: 3 added · 1 changed — Jordy"), pushes, and releases the lock.
- **Locks** are files under `locks/`, acquired through Git's own push atomicity: whoever pushes the lock first holds the tenant; everyone else sees who, on which Mac, since when. A stale lock can be broken from the tenant view.

Everything in the repository is reviewable: tenant records are JSON, history is JSON, state is encrypted but versioned.

## What is — and is not — in the repository

| In the repository | Never in the repository |
| --- | --- |
| Tenant records (names, selected blocks, settings, scope) | API client secrets |
| Engine state and plans — **encrypted** (AES-GCM, per-tenant passphrase) | State passphrases, in the clear |
| History, snapshots, adopted configuration | Secret-typed block settings |
| Shared catalogs and presets | Private encryption keys |
| Credential envelopes — **end-to-end encrypted** | |

Anyone with repository access can see tenant names, structure and encrypted state, so scope repository access accordingly.

## Sharing credentials, end-to-end encrypted

So a teammate can work on a tenant without re-entering its credentials:

1. Each engineer gets a Curve25519 identity on first Team Mode use. The private key stays in their Keychain; only the public key is published to the repository (`team/engineers/`).
2. **Share Credentials** seals each tenant's secrets once per engineer (X25519 key agreement → HKDF-SHA256 → ChaCha20-Poly1305) into `team/secrets/`. The repository only ever carries ciphertext.
3. On sync, each Mac decrypts the envelopes addressed to it and stores the secrets in its own Keychain.

A new engineer appears in the team list after their first sync; an existing member runs **Share Credentials** once to grant them access. GitHub never sees a usable secret.

## Setting up

**Create** (first engineer): Settings → Team → **Create Team Space…** — point it at an empty private GitHub repository (the app can create one via `gh`). The existing local store is pushed as-is.

**Join** (everyone else): Settings → Team → **Join Team Space…** with the repository URL. Local tenants are merged in; conflicting tenant IDs are reported and skipped, not overwritten. Ask a teammate to share credentials, then you're fully operational.

**Leave**: Settings → Team → detach the remote. The store keeps working locally, with full history.

## Requirements and caveats

- Each Mac needs push access with Git credentials already configured (SSH key or `gh auth login`); the app never prompts for Git passwords.
- Locks don't expire on their own — the holder, host and age are always shown, and **Break Lock** is available when a Mac went away mid-operation.
- Two operations on the same tenant from the same Mac are serialized by the engine itself.
