#!/usr/bin/env bash
# Publishes web/ (PWA + Scriptable build) to the gh-pages branch → https://pandasam0.github.io/m9rofi/
# Runs the tests first; refuses to publish if any fail.
set -euo pipefail
cd "$(dirname "$0")/.."
node --test web/test/engine.test.mjs >/tmp/m9rofi-test.log 2>&1 || { tail -40 /tmp/m9rofi-test.log; echo "TESTS FAILED — not published"; exit 1; }
# Publishes what is committed (HEAD). Build web/scriptable.js and commit before running.
if ! git diff --quiet HEAD -- web; then echo "uncommitted changes in web/ — commit first"; exit 1; fi
git subtree split --prefix web -b ghp-tmp -q
git push -q origin ghp-tmp:gh-pages
git branch -D ghp-tmp -q
echo "published $(git rev-parse --short HEAD)"
