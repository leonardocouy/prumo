# Prumo identity

Prumo brings order to work recorded across coding agents.
The name means a plumb line in Portuguese. The mark combines a clear P with a hanging copper weight.

The app icon is defined in `prumo-icon.svg`. The app's sidebar uses the bundled icon to keep the mark consistent.

| Role | Color |
|---|---|
| Ink blue | `#243E51` |
| Warm white | `#FFFEFA` |
| Copper | `#A9653F` |
| Soft paper | `#F4F2ED` |
| Divider | `#DEDAD1` |

Use the system font. Keep headings compact, surfaces quiet, and copper accents limited to small details.
Keep at least one quarter of the mark's width clear around it.
Use the full app tile in the Dock. Check the mark at 16 and 32 pixels before changing its geometry.

Regenerate the icon files with `swift scripts/make-icon.swift scripts`, then `iconutil -c icns scripts/Prumo.iconset -o scripts/Prumo.icns`.
The SVG is the editable source. PNG and ICNS files are generated exports.
