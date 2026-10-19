#!/bin/sh
# Flushes the DNS cache; safe to run at any time.
/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder
exit 0
