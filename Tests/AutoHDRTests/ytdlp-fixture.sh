#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = '--version' ]; then printf 'fixture-1\n'; exit 0; fi
done
case "$*" in *--ignore-config*--dump-single-json*--skip-download*--simulate*--no-playlist*) ;; *) exit 91 ;; esac
case "$*" in *SLOWvideo01*) /bin/sleep 20 & wait; exit 2 ;; esac
printf '%s\n' '{"formats":[{"vcodec":"vp9","dynamic_range":"HDR10"},{"vcodec":"none","dynamic_range":"SDR"}]}'
