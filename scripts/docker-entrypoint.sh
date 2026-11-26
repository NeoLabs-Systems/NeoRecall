#!/bin/sh
# Hands the data volume to the unprivileged user and runs the command as it. The
# Node.js image ran as root, so an upgraded volume is still owned by root.
set -eu

[ "$(id -u)" = 0 ] || exec "$@"

data="${NEORECALL_HOME:-/data}"
case "$data" in
  /*[!/]*) ;;
  *) echo "NEORECALL_HOME must be an absolute directory below /, not '$data'." >&2; exit 1 ;;
esac

# The Node.js image kept its data in /root/.neorecall. Starting on an empty
# volume instead would look like every recording is gone.
if [ -f /root/.neorecall/data/neorecall.sqlite3 ] && [ ! -f "$data/data/neorecall.sqlite3" ]; then
  echo "Found NeoRecall data in /root/.neorecall. Mount that volume at $data instead." >&2
  exit 1
fi

mkdir -p "$data"
# Only what is wrongly owned, without following links or leaving the volume.
find "$data" -xdev \( ! -user neorecall -o ! -group neorecall \) -exec chown -h neorecall:neorecall {} +

HOME="$data" exec setpriv --reuid=neorecall --regid=neorecall --init-groups -- "$@"
