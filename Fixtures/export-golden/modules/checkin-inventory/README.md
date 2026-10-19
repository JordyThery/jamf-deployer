# Check-in & Inventory

Sets the tenant-wide computer check-in and inventory collection settings.

- **Check-in every** — how often Macs contact Jamf Pro (default 15 minutes).
- **Run policies at startup / login** — installs the startup script and login hook so policies with those triggers run.
- **Inventory** — reports application usage, software updates, local accounts, package receipts, printers, services and certificates. Home folder sizes are off by default because they slow inventory down.

These are tenant-wide settings: one block can own them. Removing the block keeps the current values in Jamf.
