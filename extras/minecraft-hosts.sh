#!/bin/sh
# Back-compat wrapper: the Mojang pin now lives in hosts-pin.sh.
exec "$(dirname "$0")/hosts-pin.sh" minecraft "$@"
