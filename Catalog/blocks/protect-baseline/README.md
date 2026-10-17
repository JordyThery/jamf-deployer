# Jamf Protect Baseline

A safe endpoint-security starting point in Jamf Protect:

- **Telemetry** for the core event categories (network telemetry is optional
  — it is high-volume).
- **Action configuration** forwarding alerts of every severity to Jamf
  Protect cloud.
- An empty, named **exception set** ready for your exclusions.
- A **plan** wiring it all together — in **report-only** mode by default.
  Switch to "Block and report" once pilot alerts look clean. Tamper
  prevention blocks by default.

Needs the tenant's Jamf Protect connection (console URL + API client) —
set it up in the connect wizard or Day 0 tab. Deploying the plan to devices
still happens through Jamf Pro (Protect deployment sync).
