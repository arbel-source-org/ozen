#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
failed=()
step() {
    local name=$1; shift
    if "$@" > /tmp/ozen-ci-local.$$ 2>&1; then
        echo "ok    $name"
    else
        echo "FAIL  $name"
        tail -15 /tmp/ozen-ci-local.$$
        failed+=("$name")
    fi
}
step translations python3 scripts/check-translations.py
step doc-quotes python3 scripts/check-doc-quotes.py
step no-real-values python3 scripts/check-no-real-values.py
step swift-test swift test
step server-tests bash -c "cd server && python3 -m unittest -q test_ozen_server test_pairing"
rm -f /tmp/ozen-ci-local.$$
if [ ${#failed[@]} -gt 0 ]; then
    echo "${#failed[@]} failed: ${failed[*]}"
    exit 1
fi
echo "all portable CI checks pass (the iOS build runs only on CI)"
