# CellDock v0.3.1

CellDock v0.3.1 improves DJI QDC507 / Quectel EG25-G support on macOS while preserving existing calling, messaging, cellular networking, eSIM, proxy, VoWiFi, localization, and Sparkle update capabilities.

## Highlights

- Added real-time three-sensor module temperature monitoring through `AT+QTEMP`.
- Added the primary module temperature to the macOS menu bar and status popover.
- Added all three temperature readings and a textual thermal status to module details.
- Added approximately 10-second background temperature refresh using the existing serialized AT command path.
- Paused temperature polling during calls and other modem-critical operations.
- Hidden unavailable temperature values when a module is disconnected; no false `0°` placeholder is shown.
- Restored temperature monitoring automatically after the module is reconnected.
- Improved QDC507 call control, permission handling, and modem stability.

## Release information

- Version: 0.3.1
- Build: 105
- Commit: `f61b764379ca1e928cee503d24ebc2f0b4eba7a2`
- Package: `CellDock-0.3.1-universal-community-unnotarized.zip`
- SHA-256: `8124da12b37d4b25d704199582d3bc9a43b0ab20568696af6c79428dbdd158fd`
- Architectures: Apple silicon (`arm64`) and Intel (`x86_64`)
- System requirement: macOS 14.0 or later

## Signing notice

The community archive is certificate-signed with Hardened Runtime enabled, but is not Apple-notarized. Gatekeeper will not accept it as a notarized Developer ID distribution until the release is rebuilt with a Developer ID Application certificate, submitted to Apple, and stapled.

## Known non-blocking diagnostics

During physical module removal or recovery, macOS may occasionally log AppKit `Invalid view geometry`, eUICC `operation_unavailable`, or Metal `MDB_MAP_FULL` messages. Live validation found no associated crash, restart, modem failure, or loss of temperature recovery.
