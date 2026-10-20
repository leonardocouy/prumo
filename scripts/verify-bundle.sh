#!/bin/bash
set -euo pipefail
bundle="${1:?Usage: verify-bundle.sh path/to/Prumo.app}"
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
python3 - "$bundle" <<'PY'
from pathlib import Path
import sys
bundle = Path(sys.argv[1])
allowed = {
    'Contents/Info.plist', 'Contents/MacOS/Prumo',
    'Contents/Resources/Prumo.icns', 'Contents/Resources/LICENSE.txt',
    'Contents/Resources/ThirdPartyLicenses.html', 'Contents/_CodeSignature/CodeResources',
}
unexpected = [str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file() and str(p.relative_to(bundle)) not in allowed]
if unexpected:
    raise SystemExit('Unexpected bundle files: ' + ', '.join(unexpected))
print('Verified ARM64 bundle, macOS 15 target, system dependencies, and resource allowlist.')
PY
