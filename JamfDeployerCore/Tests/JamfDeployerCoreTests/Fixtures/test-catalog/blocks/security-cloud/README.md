# Security Cloud

The complete Security Cloud ↔ Jamf Pro chain:

1. **UEM Connect** — binds Jamf Security Cloud to this Jamf Pro tenant via
   the platform (no manual API client): devices sync on a schedule, risk
   levels flow back into Jamf Pro, and failing credentials pause syncs
   instead of hammering the API.
2. **Activation profile** (macOS) — the enrollment entry point deciding
   which capabilities (content controls, network security) enrolling
   devices get. With UEM Connect established, Security Cloud can push the
   enrollment configuration profile down to Jamf Pro.

**Entitlement required**: the Platform environment must include Jamf
Security Cloud. Without it, deploying stops with a clear message and
nothing else in the baseline is affected.

## What the deploy gives you

The activation code (`activation_profile_id` output) is what devices enroll
with, verified against a real tenant's enrollment profile:

- Enrollment link: `https://e.wandera.com/<activation-code>` (also output
  as `enrollment_url`).
- The Jamf Trust configuration profile Security Cloud pushes carries
  `activationProfileUrl` (the link above), `activationType: AP`, MDM
  substitution variables (`$EMAIL`, `$UDID`, `$FULLNAME`) and tenant-issued
  `apiKey`/`secretKey` — those keys are secrets and never belong in a
  building block.
