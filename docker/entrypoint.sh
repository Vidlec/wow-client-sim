#!/bin/sh
# The container's start: /data's folders made (a fresh volume, or a folder of the host mounted there, has none of them
# yet), then the command given (the server by default, or the CLI: `addonsim test` in a mounted project).
set -e
mkdir -p /data/cache /data/saved /data/interface /data/config
exec "$@"
