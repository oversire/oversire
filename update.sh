#!/bin/bash
# Pull the latest code, rebuild, and relaunch OverSire.
# Usage: ./update.sh [branch]   (defaults to the currently checked-out branch)
set -e
cd "$(dirname "$0")"
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"
# build.sh stops the running app, refreshes its installed copy, and restarts it.
./build.sh
echo "OverSire restarted on $BRANCH @ $(git rev-parse --short HEAD)"
