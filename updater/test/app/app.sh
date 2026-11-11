#!/bin/sh
set -eu
cd /state
[ -f restore.pending.sqlite ] && mv restore.pending.sqlite state.sqlite
last=$(cat version 2>/dev/null || true)
if [ -n "$last" ] && [ "$last" != "$VERSION" ] && [ -f state.sqlite ]; then
  mkdir -p backups
  [ -f "backups/before-$VERSION.sqlite" ] || cp state.sqlite "backups/before-$VERSION.sqlite"
fi
# A migration: each version leaves its mark in the data
echo "migrated by $VERSION" >> state.sqlite
[ -z "$BROKEN" ] || { echo "app $VERSION: broken on purpose"; sleep 2; exit 1; }
mkdir -p /www/api
echo "{\"status\":\"ok\",\"version\":\"$VERSION\"}" > /www/api/health
echo "$VERSION" > version
echo "app $VERSION: listening"
exec httpd -f -p 80 -h /www
