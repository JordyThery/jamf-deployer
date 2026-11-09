# Changelog

## Unreleased

- **OpenTofu 1.13.9** is now built in (was 1.13.2). It fixes saving the
  deployment state after a first deploy that stopped partway, and a crash on
  a broken state encryption setting.
- **Capture, Adopt and Clone use the built-in engine plugins' versions.**
  The exporter no longer downloads a newer jamfplatform, jamfpro or
  jamfprotect plugin, whose output the built-in engine may not read.
- **Test Connection in Settings › Connections also checks the read
  permissions** a deploy needs first (categories, scripts, Automated Device
  Enrollment, Apps and Books), and says which permission or Jamf Pro
  privilege to add.
- **A Keychain that can't be read is reported as such** in Adopt, Export,
  Day 0, the app pickers, the preflight and the team passphrase, instead of
  “the client secret is missing”. Update Client Secret… no longer asks for a
  new recovery passphrase when the saved one only can't be read right now,
  and a recovery sheet is never saved without its passphrase.
- **A catalog-sources list or a “Not a secret” list that can't be read** is
  kept as a dated copy next to it (on this Mac only, never shared with a
  team), and an earlier copy is never replaced.

## 1.2.0 — 2026-11-02

### Adopt, Capture and the store

- **Adopt takes objects that hold a secret again.** A Wi-Fi password, a VPN
  shared secret, a SCEP challenge or a password in a script is kept in this
  Mac’s Keychain as a secret setting, never in the tenant record. If a
  flagged value isn’t a secret, mark it “Not a secret” to adopt it as it is.
- **Adopted secret settings** are listed on the tenant page, under the
  building blocks. Another Mac (in Team Mode, a teammate’s) enters each
  value there once before it can preview, check or deploy that tenant;
  until then those actions say which value is missing and where to enter it.
- **Capture keeps an object it can’t turn into a secret setting**, with a
  warning to review the block, instead of stopping.
- **The store’s secret review can mark every finding at once** with “Mark
  All as Not a Secret…”. In Team Mode it says that the files are then shared
  with your team on the next sync.
- **Deploy history masks what looks like a secret** before it’s saved, on
  top of what the engine already masks. A finding left in a deploy’s plan
  never stops saving, previews, checks or deploys; the main window shows a
  notice with Review… instead. A deploy’s log is checked like any other file.

### Team Mode

- **Leave Team Mode works with tenants that were never deployed.** Only
  tenants with a deployment record in the team space are moved back; an
  unfinished baseline or a missing client secret no longer stops it.
- **SSH sign-in for the team space** first tries the keys in your SSH agent.
  If they don’t give access to the team repository (an agent holding only a
  work key, for example), it signs in with your SSH key file without a
  passphrase (`~/.ssh/id_ed25519`, `id_ecdsa` or `id_rsa`) instead. A key
  file with a passphrase still needs to be added to the agent.

### Deploys

- **Preview stops when a new object would take a name that’s already used
  in Jamf** (Jamf Platform API tenants), and says so, instead of Jamf
  refusing it during the deploy. Use Adopt Existing Configuration to manage
  the existing object, or choose another name or prefix.
- **Packages upload straight to Jamf Cloud’s storage** on Jamf Cloud
  tenants. A block that uploads a package needs the
  `jamf-cloud-distribution-service-files:create` permission: captured
  blocks with a package list it, and Run Preflight names it.
- **Enrollment customization icons** are downloaded again for Jamf Pro API
  tenants hosted on Jamf Cloud.
- **When Jamf asks the app to wait** before trying again, the main window
  shows it, with Stop to end the wait.
- **A Keychain that can’t be read is reported as such**, instead of as a
  missing client secret.

### Menus and accessibility

- **Every action is in the menu bar:** File (Connect a Tenant… ⌘N, Export as
  Terraform… ⇧⌘E), View (Dashboard ⌘1, Building Blocks ⌘2, History ⌘3, a
  tenant’s sections, Show Technical Details), Tenant (Check All Tenants ⇧⌘R,
  Adopt, Add a Custom Object, Baseline Updates, Run Preflight, Update Client
  Secret, Hand Over, Remove Tenant, Roll Out) and Catalog (Manage Sources…,
  Add Git Catalog…). Preview Changes… stays on ⌘P and is dimmed when there’s
  nothing to preview. Deploy… is gone from the Tenant menu: every deploy
  starts from Preview Changes…. Menu commands are dimmed while a sheet is
  open.
- **The Preview and Roll Out sheets can be resized**, and **Cancel
  Hand-Over…** asks before it restores the baseline.
- **Demo Mode is marked at the top of the sidebar,** with Turn Off.
- **VoiceOver** announces finished previews, deploys, checks and preflights,
  and repeated buttons name their row. The fleet table can be used from the
  keyboard. When a plan removes objects, Return no longer starts the deploy.

### Under the hood

- The Jamf Platform API engine plugin is 1.7.2.
- Settings no longer has an Appearance choice: the app follows the Mac’s
  own setting.

## 1.1.1 — 2026-11-01

- **No more duplicate policies or macOS configuration profiles after a Jamf
  error.** When Jamf reports an error while creating a policy or macOS
  configuration profile but creates it anyway, the app recognizes the object
  again instead of creating a duplicate.

## 1.1.0 — 2026-11-01

### Team Mode

- **The team store syncs one step at a time.** Saving, pulling and
  publishing never overlap, and every change on this Mac is saved before the
  team’s changes are pulled in.
- **A pull that conflicts is undone.** This Mac’s changes are kept, and the
  app says: “This Mac and the team space both changed …, so nothing was
  synced. This Mac’s changes are kept, and previews, checks and deploys wait
  until the store syncs.” A store with an unfinished Git merge is never
  saved or synced; previews, checks and deploys wait until it’s resolved.
- **Nothing runs on a baseline that may be out of date.** When the team sync
  fails, Preview Changes, Check for Changes, deploys and Check All Tenants
  stop with “The team space couldn’t be synced, so nothing was started: this
  Mac may not have the team’s latest changes.”
- **Changes to a tenant are saved, and shared with the team, a moment after
  they’re made,** wherever in the app they’re made. Changes made since a
  preview are saved before its deploy starts.
- **Check All Tenants syncs once, before it starts,** instead of once per
  tenant.
- **The team passphrase is checked against the team space’s encrypted
  state.** A new team space stores a small encrypted check for it, and an
  existing one gets that check the next time the passphrase is confirmed.
  A wrong passphrase is refused (“That passphrase doesn’t open the team’s
  deployment state. Check it with a teammate.”), and one that couldn’t be
  checked isn’t accepted either.
- **Turning Team Mode on or off moves the state of every tenant that has
  any,** including tenants whose first deploy partly failed. Only state
  that actually moved is retired on this Mac.
- **Removing a tenant that was never deployed works in Team Mode.** There is
  no state in the team space to delete, so the removal no longer fails.
- **SSH keys protected by a passphrase need the SSH agent.** Instead of
  failing without explanation, the app says: “Your SSH key is protected by
  a passphrase, which the Team Mode state backend can’t ask for. Add the key
  to your SSH agent …, then try again.”
- **In Team Mode, a new client ID or username needs its own secret** in
  Update Client Secret…: “A new client ID needs its client secret.” or “A
  new username needs its password.”

### Tenants

- **Remove Tenant… is unavailable while a deploy, preview or check runs.**
  If one starts while the confirmation is open, the removal is refused with
  “Wait for the running deploy, preview or check to finish, then remove the
  tenant.”
- **Removing a tenant the app manages objects on asks for its name.** The
  confirmation says that the tenant’s deployment state (and, outside Team
  Mode, its passphrase) is deleted for good, that the app then no longer
  knows which objects it manages there, and points to Hand Over Tenant… or
  Export as Terraform… to keep them managed elsewhere.
- **Settings › Connections no longer removes a managed tenant.** It says:
  “This tenant has objects the app manages. Remove it with Remove Tenant…
  in the sidebar, which asks you to type its name.” It also refuses while
  a deploy, preview or check runs.
- **Force Unlock… is unavailable while any deploy, preview or check runs,**
  with the help text “Wait for the running deploy, preview or check to
  finish”.
- **Handed-over tenants can’t be previewed, checked or deployed:** “This
  tenant was handed over: this app no longer manages it, so it can’t be
  previewed, checked or deployed here.”
- **Demo mode waits for running work.** Try Demo Mode is unavailable, and
  the switch waits, while an export, Adopt’s search, a Day 0 step or a
  rollout is under way.
- **Editing the baseline keeps a check that just finished.** Checking or
  unchecking blocks and applying a preset no longer undoes the result of a
  check that completed while the screen was open.

### Deploy and preview

- **The ordered retry after a blocked delete applies only the approved
  changes.** When a delete fails because another object still uses it, the
  app finishes the deploy in order only if what remains is identical to the
  approved preview. Otherwise it stops: “The remaining changes are no longer
  the ones in the preview you approved, so they weren’t deployed. Preview
  the changes again.”
- **After a failed create, an object that already existed before the deploy
  is never adopted.** Only an object the deploy itself left behind is
  taken over, and nothing is adopted when the tenant’s state can’t be read.
- **Esc no longer closes the preview while a deploy runs,** so its result
  and errors always show.
- **Save Recovery Sheet… needs the passphrase on this Mac.** Without it, the
  button is unavailable and the app explains where to enter it: “This Mac
  doesn’t have the team passphrase, so there’s no recovery sheet to save.
  Enter it in Settings › Team, then preview again.” (outside Team Mode:
  with Update Client Secret… on the tenant page). A sheet counts as saved
  only when it holds the passphrase.

### Day 0

- **Production tenants ask first.** Uploading a server or location token,
  creating a branding and linking Jamf Protect show a confirmation, such as
  “Upload Server Token to “Tenant”?”, which notes that “Day 0 steps are
  written straight away, without a preview.”
- **The tenant is checked again after every step,** also when the step
  failed, since a call that timed out may still have reached Jamf.
- **The Day 0 buttons are unavailable while a step or that check runs,** so
  a second click can’t create a second branding or location.
- **The guided tour says which steps write without a preview:** only Day 0
  Setup’s one-time steps, when you start them.

### Rollouts

- **The order is fixed when the rollout starts.** A teammate renaming a
  tenant mid-rollout no longer reorders it.
- **A tenant removed since the rollout started stops its step** with “This
  tenant is no longer connected.”
- **Esc no longer closes the rollout while a tenant’s step runs,** so a
  staged release is always put back.

### Building blocks and capture

- **“Prefix all names” prefixes object names only.** Names inside smart
  group criteria, display fields and payloads are left alone.
- **Exported files with braces inside strings, heredocs or comments are read
  correctly.** A file the app can’t split cleanly stops the capture instead
  of losing lines: “The exported configuration has a block that never
  closes … Nothing was changed; export again, or leave that object out.”
- **A captured block records its origin tenant only as a hash,** so a block
  shared through a catalog doesn’t publish the tenant’s environment ID.
- **The Automated Device Enrollment instance and Apps and Books location
  names are required settings with no default.** Each tenant enters its own;
  the capture shows the origin tenant’s name as a hint.
- **A capture that stops leaves no half-written block behind,** so the same
  block can be captured again.
- **Exported values of every shape are kept:** multi-line text, numbers,
  true/false values, lists and maps, not only single-line text.
- **A choice setting outside the block’s list is refused** before anything
  is deployed: “The block … doesn’t offer … for its … setting. Open its
  settings and choose one of the listed values.”
- **An unreadable preset is skipped and listed** in the catalog, instead of
  hiding the whole catalog source.
- **An unreadable app list is never deployed.** The block settings warn
  “This block’s app list can’t be read. Choose the apps again.”, and closing
  the picker without choosing apps no longer empties the list.
- **Secret settings are saved when you finish typing** (Return, leaving the
  field, closing the settings or a short pause), not on every keystroke.
- **A local catalog folder is told apart from a folder whose name starts the
  same way.**

### App Store apps

- **Opening the App Store picker no longer changes the block’s Apps and
  Books location.** Only picking a location, or adding an app from it, does.
- **Apps without licenses in the shown location are flagged:** “No licenses
  in “Location”. Remove it, or pick the location that has them.”

### Export as Terraform and exports

- **Moving tenants to a repository needs a second acknowledgment:** “I
  understand that the state on GitHub isn’t encrypted”. The state holds the
  tenants’ secret settings in plain text.
- **In Team Mode, moved tenants’ state is deleted from the team space,** so
  it can’t be brought back and used against the repository.
- **Enrollment customization icons are downloaded only over HTTPS from the
  tenant’s own Jamf Cloud address,** and each download shows in the Activity
  Log.
- **A snapshot that fails to save leaves an earlier file with the same name
  untouched.**

### Security

- **The secret check finds more:** credentials passed with curl -u and
  similar options, Basic, Bearer and Token Authorization headers, passwords
  that start with a $ sign, quoted passphrases that contain spaces, and
  profile payloads in the stored plan history.
- **Exported variable values are checked before Adopt or a capture uses
  them.** In a capture, a value that looks like a secret becomes a secret
  setting entered per tenant, never a default.
- **Replacing a secret with a setting no longer changes object names** that
  happen to contain the same text.
- **The support bundle replaces device identifiers, usernames and IP
  addresses with placeholders.**

### Updates

- **The check for newer built-in tools runs again on the next launch when
  the Mac was offline,** and ignores prereleases.

### Accessibility and keyboard

- **Status and warning text is easier to read:** the colored symbol carries
  the status and the text stays in the normal label color. Token expiry in
  the fleet table also shows a warning symbol, not only a color.
- **Field changes in previews and drift show “−” and “+” lines,** which
  VoiceOver reads as “Before” and “After”.
- **Building-block cards open with the keyboard and VoiceOver.**
- **VoiceOver names the wizard’s steps, progress spinners, Remove buttons
  in the app pickers and the rollout’s Ring picker.**
- **Return confirms and Esc goes back in more sheets,** including the
  production confirmation in the preview.
- **Tenant › Preview Changes… has an ellipsis,** and disabled Export and Add
  Tenant buttons say why.

### Text

- **American English throughout, “Apple Business” instead of “Apple
  Business Manager”, and consistent names** for screens and commands.
- **The Jamf components listed under Settings › Advanced are called
  plugins.**
- **Clearer messages when Jamf refuses the sign-in or a secret is missing
  from the Keychain,** each saying where to enter it: Update Client Secret…
  or Update Password… in the tenant’s Connection section.
- **Clearer messages for a busy Jamf server, a temporary server problem and
  an error the app doesn’t recognize.**
