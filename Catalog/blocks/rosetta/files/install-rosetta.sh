#!/bin/zsh
# Managed by Jamf Deployer · rosetta@0.0.1
# Installs Rosetta 2 on Apple silicon Macs if it is not already present.

if [[ "$(/usr/bin/arch)" != "arm64" ]]; then
  echo "Not an Apple silicon Mac, nothing to do."
  exit 0
fi

if /usr/bin/pgrep -q oahd; then
  echo "Rosetta 2 is already installed."
  exit 0
fi

/usr/sbin/softwareupdate --install-rosetta --agree-to-license
exit $?
