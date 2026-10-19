# Self Service App

Installs the Self Service app in /Applications on every managed Mac, opens it on the Home page, turns on notifications for new items, and sets whether users log in (not required by default). Through the Jamf Platform API, other Self Service settings are left as they are; through the Jamf Pro API, which sets every option at once, they get Jamf Pro's defaults: no remembered logins, no FIDO2, a "Bookmarks" section and All Items as the home category.

A tenant-wide setting: one block can own it. Removing the block keeps the current values in Jamf.
