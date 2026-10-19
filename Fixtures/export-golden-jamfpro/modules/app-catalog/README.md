# App Catalog

Deploys apps from Jamf's App Catalog (App Installers): Jamf hosts, installs
and updates the packages — no packaging or re-uploading on new versions.

Pick apps with the built-in picker. Per app you choose how it arrives
(installed automatically or offered in Self Service) and how it updates
(always latest, or pinned to the version current at deploy time).

Notes:
- Needs a Jamf-cloud-hosted tenant with the Cloud Services Connection
  established (the preflight checks this).
- App Installers can only be scoped to smart groups, so the static Pilot
  group is not offered for this block.
