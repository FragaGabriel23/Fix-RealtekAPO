# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/), and the
project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] — 2026-09-29

### Added
- **`[9] Restart Windows audio`** — reloads the effects chain so changes take
  effect without rebooting. Also offered at the end of cleaning and blocking.
- The diagnosis, cleaning and blocking screens now list every CLSID in the
  effects chain with its vendor and the DLL behind it, which makes bug reports
  actionable and names effects the vendor map does not recognise.
- Vendor detection now also looks in the packaged COM catalog (MSIX / Store
  apps) and in the Windows APO catalog (`AudioEngine\AudioProcessingObjects`).
- Version shown under the menu banner.
- When a registry write fails, the owner and access rules of the key are
  printed in the same run.

### Fixed
- **Cleaning failed with "requested registry access is not allowed"** on
  endpoints that had never been touched by hand. The keys are owned by
  TrustedInstaller or SYSTEM and often grant Administrators read access only;
  cleaning now takes ownership and obtains write access first, and writes
  through the registry API directly instead of `Set-ItemProperty`, whose
  provider requests broader rights than are granted.
- **A single CLSID in a property was read as a string**, so indexing it yielded
  characters. Harmless in the cases observed, but a lone non-Realtek CLSID
  could have been written back as `{`. Chains are now always handled as arrays.
- The device count printed as `{0}` on Windows PowerShell 5.1 when one device
  was selected.
- Vendor lookup read the COM server path unreliably, reporting known vendors
  as Unknown.

### Changed
- Removing the CAPX subkey is now described as optional and cosmetic, and a
  failure to remove it is reported as a note rather than an error. The key
  holds only metadata, the service recreates it on every run, and the block is
  what keeps the effects chain clean.

## [1.0.0] — 2026-09-17

First public release.
