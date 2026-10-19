# Compliance — CIS Level 1

Builds a Jamf compliance benchmark from the CIS Level 1 baseline with every
rule enabled at the baseline's recommended values, targeted at the chosen
device group.

Starts in monitor mode: devices are evaluated and reported, nothing is
changed. Review the results, then — if you want remediation — remove this
block and re-add it with “Monitor and enforce”: the mode is baked into the
benchmark, so changing it recreates the object (Jamf has no update path).
