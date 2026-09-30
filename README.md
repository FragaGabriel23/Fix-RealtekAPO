# Realtek APO Fix

**The Realtek audio service injects its APOs into audio endpoints that do not belong to Realtek.**
Two audio processors then fight over the same stream, and your USB or wireless headset starts
losing gain, crackling and behaving as if it had a transmission fault.

This repository contains a PowerShell tool that finds it, cleans it, and stops it from
coming back — without uninstalling anything and without losing THX, Dolby, Nahimic or any
other legitimate effects.

Interface available in **English** and **Português (Brasil)**.

---

## Symptoms

- USB / wireless headset or speakers with the gain dropping and returning on its own
- Crackling, popping, hiss, unstable volume
- Per-application volume control behaving erratically
- The problem comes back **after every reboot**, even after you fix the registry by hand
- Uninstalling the headset software "fixes" it — at the cost of every feature it provides

Reported on Razer BlackShark V2 Pro, but the mechanism is not brand-specific: any non-Realtek
endpoint on a machine with a Realtek codec can be affected.

---

## Cause

The Realtek audio service (`RtkAudUService64.exe`, registered as `RtkAudUService` or
`RtkAudioUniversalService` depending on the driver version) walks the Windows audio endpoints
and appends Realtek's APOs to the effects chain of devices that are not Realtek.

The effects chain lives at:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\{Render|Capture}\{endpoint}\FxProperties
```

in the property set `{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}`:

| Property | Meaning |
|---|---|
| `,13` | SFX — stream effects |
| `,14` | MFX — mode effects |
| `,19` | SFX offload |
| `,20` | MFX offload |

A Process Monitor capture shows the service reading the existing chain and writing it back with
its own CLSIDs appended, **in under a millisecond, with no hardware or preset lookup in between**.
It preserves what was already there — which is exactly why THX keeps showing up next to Realtek:

```
,13   {C792E395-...}                      ->  {C792E395-...} , {905399BE-...}
,14   {68650828-...}                      ->  {68650828-...} , {9063CBD4-...}
,19   (absent)                            ->  {90B31DF6-...}
,20   (absent)                            ->  {90C35236-...}
```

The `905399BE` / `9063CBD4` / `90B31DF6` / `90C35236` CLSIDs resolve to `RtkIntU642.dll`
(`realtekuapo2.inf`) — they are Realtek's, on a device that is not Realtek's.

Full write-up, including the hypotheses that were tested and discarded:
[docs/INVESTIGATION.md](docs/INVESTIGATION.md).

---

## How the fix works

Windows can give a service an identity of its own — the **per-service SID**, an officially
supported feature:

```
sc.exe sidtype <ServiceName> unrestricted
```

The service then runs as `NT SERVICE\<ServiceName>`, and that identity can be named in an ACL.
The tool applies a **Deny** rule for `SetValue, CreateSubKey, Delete` to that identity alone,
on the `FxProperties` key of the endpoint you choose.

The result:

- The Realtek service can still read the key — nothing crashes, nothing logs errors
- It can no longer write to it — the contamination stops at the source
- Synapse, THX, Dolby and every other application keep configuring the device normally
- Realtek onboard audio keeps **all** of its effects
- The service stays in **Automatic**; nothing is disabled or uninstalled

The audio endpoint keys are owned by `TrustedInstaller`, so the tool enables
`SeTakeOwnershipPrivilege` in its own process token, takes ownership, applies the rule, and
records the original owner so it can be restored on revert.

---

## Usage

1. Download `Fix-RealtekAPO.ps1`
2. Open **PowerShell as Administrator**
3. Run it:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Fix-RealtekAPO.ps1
```

To skip the language prompt:

```powershell
.\Fix-RealtekAPO.ps1 -Language en     # English
.\Fix-RealtekAPO.ps1 -Language pt     # Português (Brasil)
```

### Recommended order

| Step | Menu option |
|---|---|
| 1 | `[1] Diagnose` — confirm this is your case |
| 2 | `[3] Apply block` — backs up, cleans, protects, and offers to restart Windows audio so the fix applies immediately |
| 3 | **Reboot** — the service runs at startup and at other moments during normal use; this is what proves the block holds |
| 4 | `[1] Diagnose` — confirm the endpoint stayed clean |

### Menu

```
[1] Diagnose             see the current state
[2] Clean contamination  remove the stray Realtek APOs
[3] Apply block          clean + prevent it from returning
[4] Revert block         undo the protection
[5] Service control      stop / disable / re-enable
[6] Backups              list the backups created
[7] About the problem    explanation and recommended order
[8] Idioma               switch language
[9] Restart audio        apply changes without rebooting
[0] Exit
```

Nothing is hardcoded: the service name is detected by scanning the installed services, the
endpoints are enumerated from the registry, and each CLSID in a chain is resolved to the DLL
that registers it — which is how the tool tells a Realtek APO from a THX, Dolby, Nahimic,
Creative, Waves, Razer, Sennheiser, SteelSeries or Logitech one, instead of relying on a list
of known GUIDs.

The diagnosis lists every CLSID in each effects chain with its vendor and the DLL behind it.
If you open an issue, include that output — it is what makes a report actionable.

---

## Safety

- A `.reg` backup of the endpoint is exported **before** any change, to
  `Desktop\RealtekAPOFix_Backups`
- The original owner of each modified key is saved to `original_owners.txt` in the same folder
- Cleaning **empties** the affected properties instead of deleting them, and removes only the
  CLSIDs that resolve to Realtek — everything else in the chain is preserved
- `[4] Revert block` removes the Deny rule and restores the original owner
- Nothing is uninstalled, and the Realtek service is never disabled unless you explicitly ask
  for it in option `[5]`
- When a key is read-only for administrators, the tool takes ownership and grants the
  Administrators group write access before cleaning. The original owner is restored on
  revert; the write permission is left in place.
- Removing the CAPX subkey is optional and cosmetic: it holds only metadata and the
  service recreates it on every run. The block is what keeps the chain clean.
  
---

## Limitations

- **The endpoint GUID changes when you reinstall Synapse** (or any software that recreates the
  device). The block is tied to that GUID, so after a reinstall you have to run option `[3]`
  again on the new endpoint.
- If the contamination returns *even with the block applied*, the writer is not this service
  but another component — most likely the driver itself, via PnP. In that case, option `[5]`
  (disable the service) is the guaranteed fallback. It does not stop built-in audio from
  working; it only removes the Realtek Audio Console effects.
- Tested on Windows 10 and Windows 11, x64.

---

## Disclaimer

This tool changes Windows registry permissions and values. Backups are created automatically,
but use it at your own risk. It is not affiliated with, endorsed by, or supported by Realtek,
Razer, THX or Microsoft.

---

## License

MIT — see [LICENSE](LICENSE).

## Credits

Investigated and built by **FragaGabriel23**, using Process Monitor captures and registry diffs from an affected machine.

Português: [README.pt-BR.md](README.pt-BR.md)
