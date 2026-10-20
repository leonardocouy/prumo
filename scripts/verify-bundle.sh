#!/bin/bash
set -euo pipefail
bundle="${1:?Usage: verify-bundle.sh path/to/Prumo.app}"
mode="${2:-}"
if [[ -n "$mode" && "$mode" != --signed && "$mode" != --notarized ]]; then
    echo "Unknown verification mode: $mode" >&2
    exit 1
fi
binary="$bundle/Contents/MacOS/Prumo"
test -f "$binary"
test -s "$bundle/Contents/Resources/Prumo.icns"
test -s "$bundle/Contents/Resources/LICENSE.txt"
test -s "$bundle/Contents/Resources/ThirdPartyLicenses.html"
codesign --verify --deep --strict --verbose=2 "$bundle"
if [[ "$(lipo -archs "$binary")" != "arm64" ]]; then
    echo "Expected an ARM64-only executable." >&2
    exit 1
fi
xcrun vtool -show-build "$binary" | awk '
    $1 == "minos" { found = 1; if ($2 != "15.0") bad = 1 }
    END { if (!found || bad) exit 1 }
'
otool -L "$binary" | tail -n +2 | awk '
    $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1; print "Unexpected runtime dependency: " $1 }
    END { if (bad) exit 1 }
'
python3 - "$bundle" "$mode" "${APPLE_TEAM_ID:-}" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
bundle = Path(sys.argv[1])
allowed = {
    'Contents/Info.plist', 'Contents/MacOS/Prumo',
    'Contents/Resources/Prumo.icns', 'Contents/Resources/LICENSE.txt',
    'Contents/Resources/ThirdPartyLicenses.html', 'Contents/_CodeSignature/CodeResources',
}
if sys.argv[2] in ('--signed', '--notarized'):
    team = sys.argv[3]
    if not team:
        raise SystemExit('APPLE_TEAM_ID is required for release signature verification.')
    details = subprocess.run(['codesign', '--display', '--verbose=4', str(bundle)],
                             check=True, capture_output=True, text=True).stderr
    if f'TeamIdentifier={team}\n' not in details:
        raise SystemExit('Unexpected signing team.')
    if not re.search(r'^Authority=Developer ID Application: .* \(' + re.escape(team) + r'\)$', details, re.M):
        raise SystemExit('Expected a Developer ID Application signature.')
    if not re.search(r'^CodeDirectory .*flags=.*\bruntime\b', details, re.M):
        raise SystemExit('Hardened runtime is missing.')
    if not re.search(r'^Timestamp=.+$', details, re.M):
        raise SystemExit('Secure timestamp is missing.')
if sys.argv[2] == '--notarized':
    allowed.add('Contents/CodeResources')
if any(p.is_symlink() for p in bundle.rglob('*')):
    raise SystemExit('Unexpected symlink in app bundle.')
unexpected = [str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file() and str(p.relative_to(bundle)) not in allowed]
if unexpected:
    raise SystemExit('Unexpected bundle files: ' + ', '.join(unexpected))
print('Verified ARM64 bundle, macOS 15 target, system dependencies, and resource allowlist.')
PY
if [[ "$mode" == --notarized ]]; then
    xcrun stapler validate "$bundle"
    spctl --assess --type execute --verbose=4 "$bundle"
fi
