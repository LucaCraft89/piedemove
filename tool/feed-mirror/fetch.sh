#!/bin/sh
# Keeps /feed/gtt_gtfs.zip equal to GTT's latest export.
# A failed or implausible download never replaces the last good copy.
set -u
apk add --no-cache curl >/dev/null 2>&1 || { echo "cannot install curl"; exit 1; }

DEST=/feed/gtt_gtfs.zip
UA="PiedeMove-feed-mirror (+https://github.com/LucaCraft89/piedemove)"

while :; do
  echo "$(date -u +%FT%TZ) fetching $FEED_URL"
  # -z: only download when GTT's copy is newer than ours (If-Modified-Since).
  # --fail: an error page is never saved as a zip.
  if [ -f "$DEST" ]; then Z="-z $DEST"; else Z=""; fi
  if curl -sS --fail -L --retry 3 --connect-timeout 20 --max-time 600 \
        -A "$UA" $Z -o /feed/part.zip "$FEED_URL" 2>/tmp/err; then
    if [ -s /feed/part.zip ]; then
      # A zip starts with "PK", and the real feed is megabytes, not an error page.
      size=$(wc -c < /feed/part.zip)
      if [ "$(head -c2 /feed/part.zip)" = "PK" ] && [ "$size" -gt 1000000 ]; then
        mv /feed/part.zip "$DEST"
        echo "$(date -u +%FT%TZ) updated: $size bytes"
      else
        echo "$(date -u +%FT%TZ) rejected: not a plausible zip ($size bytes); keeping the old copy"
        rm -f /feed/part.zip
      fi
    else
      echo "$(date -u +%FT%TZ) not modified"
      rm -f /feed/part.zip
    fi
  else
    echo "$(date -u +%FT%TZ) download failed: $(cat /tmp/err); keeping the old copy"
    rm -f /feed/part.zip
  fi
  sleep $(( ${REFRESH_HOURS:-6} * 3600 ))
done
