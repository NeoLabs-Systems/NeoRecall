#!/bin/sh
# The image's `neorecall` command. `docker exec` starts as root, and files
# created that way would be unreadable to the server, so drop to its user first.
set -eu

if [ "$(id -u)" = 0 ]; then
  HOME="${NEORECALL_HOME:-/data}" exec setpriv --reuid=neorecall --regid=neorecall --init-groups -- /usr/local/lib/neorecall/neorecall "$@"
fi
exec /usr/local/lib/neorecall/neorecall "$@"
