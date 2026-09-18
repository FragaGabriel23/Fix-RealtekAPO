# Investigation

How the cause was found, what was ruled out along the way, and what evidence supports the
conclusion. The discarded hypotheses are included on purpose: several of them look convincing
and are repeated in other write-ups of this problem.

---

## 1. Starting point

A Razer BlackShark V2 Pro (USB dongle `VID_1532` / `PID_0555`) started losing gain and crackling
right after Synapse and THX Spatial Audio were reinstalled. The same hardware, the same driver
versions and the same Windows install had been working for months.

Comparing a registry export of the headset endpoint against a known-good one showed the effects
chain carrying two vendors at once:

```
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},13  =  {C792E395-...} , {905399BE-...}
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14  =  {68650828-...} , {9063CBD4-...}
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},19  =  {90B31DF6-...}
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},20  =  {90C35236-...}
```

Resolving each CLSID through `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{endpoint}\FxProperties`:

| CLSID | DLL | Vendor |
|---|---|---|
| `{C792E395-BD30-472D-9A2F-2783D7FAF812}` | THX SFX | THX |
| `{68650828-CA0F-4196-9096-5F50931AF10A}` | THX MFX | THX |
| `{905399BE-697F-47A1-B8DA-169719603BCF}` | `RtkIntU642.dll` | Realtek |
| `{9063CBD4-3561-449D-8011-E21BBB69B9DB}` | `RtkIntU642.dll` | Realtek |
| `{90B31DF6-F3AB-4867-8E21-209237065312}` | `RtkIntU642.dll` | Realtek |
| `{90C35236-DBBD-420C-B63C-FDBFE465201A}` | `RtkIntU642.dll` | Realtek |

Removing the Realtek entries fixed the audio instantly. It came back on the next boot.

---

## 2. Hypotheses that were tested and discarded

### H1 — Synapse rewrites the chain at startup
**Discarded.** A Process Monitor capture filtered on the registry path showed the writes coming
from `RtkAudUService64.exe`, not from any Razer process.

### H2 — The CAPX `Default` store acts as a template that repopulates the chain
The endpoint carries a CAPX context, `{12325c6d-6d93-4ab3-bff6-d04968d361dd}`, with `Default`,
`User` and `Volatile` stores. Microsoft documents `Default` as the store that can be repopulated
from a driver INF, which made it a natural suspect.

**Discarded.** The `Default` store was emptied; the contamination came back on the next boot
anyway. It was reduced from dozens of values to nine in the process, but that had no effect on
the outcome.

### H3 — A missing `{d86fe031-a04b-47e5-9b60-3df61dd0f181},0` makes the service fall back to `Default`
**Discarded.** The value was created manually; the contamination returned unchanged. The theory
was already weak, because the neighbouring `,1` value is incremented by the service at runtime,
which means these are counters the service maintains — not inputs it reads to decide anything.

### H4 — An eligibility preset under `ApoCondPreset` marks the endpoint as Realtek-eligible
The service reads `HKLM\SOFTWARE\Realtek\Audio\RtkAudUService\ApoCondPreset\...\GenaricPresetId`
in the same capture, which looks exactly like a policy lookup.

**Discarded on timestamps.** The read happens *after* the writes, not before:

| Capture | APO write | `GenaricPresetId` read |
|---|---|---|
| #1 | `20:41:37,422` | `20:41:37,515` |
| #2 | `21:43:09,922` | `21:43:10,012` |

Renaming the value was also tested on the machine: the contamination continued. This hypothesis
is the one most worth flagging, because it is the kind of correlation that reads as causation in
a 45,000-row log.

### H5 — `netstate2_a_AE58_g` in the endpoint's CAPX store links it to the Realtek/ASUS preset
**Discarded.** Scanning the full `MMDevices` tree showed this component present in *every*
endpoint on the machine, including the ones that are never contaminated. It is not specific to
the affected device and cannot be what distinguishes it.

### H6 — The service treats the headset as a Realtek device
**Discarded.** The capture shows the service reading the hardware IDs immediately beforehand and
seeing `USB\VID_1532&PID_0555`, with `usbaudio` as the driver. It knows exactly what the device
is. It applies its APOs anyway.

---

## 3. The test that settled it

Run on the affected machine, in this order:

1. Uninstall Synapse, THX and the Realtek driver → clean
2. Install Synapse + THX only → **clean**
3. Install the Realtek driver, service running → **still clean**
4. **Reboot** → **contaminated**

Step 3 shows the installation itself is not what writes. Step 4 shows what does: the service
running a full enumeration pass. (The service starts at every boot, but it also runs at other
moments during normal use, so "on boot" describes when it is easiest to observe, not a
precondition.)

---

## 4. What the capture actually shows

Sequence performed by `RtkAudUService64.exe` on the headset's render endpoint:

```
read  hardware IDs                    -> USB\VID_1532&PID_0555, driver usbaudio
read  device state / properties       -> active endpoint
open  FxProperties                    -> Read, Set Value
read  ,13                             -> {C792E395-...}
write ,13                             -> {C792E395-...} , {905399BE-...}
read  ,14                             -> {68650828-...}
write ,14                             -> {68650828-...} , {9063CBD4-...}
write ,19                             -> {90B31DF6-...}
write ,20                             -> {90C35236-...}
```

Read-modify-write, roughly 0.7 ms end to end, with **no preset, policy or hardware lookup
between the read and the write**. The service preserves whatever was already in the chain and
appends its own — which is why THX survives and why the two end up layered on the same stream.

About 8 ms earlier, the same pass rewrites the endpoint's CompositeFX Mode property:

```
{d04e05a6-...},0 :  {DFF21CE1-F70F-11D0-B917-00A0C9223196}  ->  {00000000-0000-0000-0000-000000000000}
```

which takes the endpoint's effects ownership away from what was configured for it.

The same pass touches the machine's NVIDIA HDMI endpoints without applying this treatment, so the
routine is not literally "every endpoint" — but nothing in the capture shows the test being
performed against any value the user or another vendor controls, which is what a surgical fix
would need.

### A note on one more misread

An earlier analysis reported the NVIDIA endpoint as having `DeviceState = 9`, which would have
explained the difference. That value is `FormFactor = 9`; the endpoint's actual `DeviceState`
is `1`, the same as the affected one. Worth mentioning because the two properties sit close
together in an export and the confusion is easy to inherit.

---

## 5. Why the fix targets permissions

With no observed input that decides the behaviour, there is nothing to configure. What remains
is denying the write itself.

Windows supports giving a service its own identity:

```
sc.exe sidtype RtkAudioUniversalService unrestricted
```

The service then runs as `NT SERVICE\RtkAudioUniversalService`, and a Deny ACE naming that
identity can be placed on the endpoint's `FxProperties` key, for `SetValue`, `CreateSubKey` and
`Delete`, with `ContainerInherit, ObjectInherit`.

The keys are owned by `TrustedInstaller`. Being an administrator grants the right to *take*
ownership but not to change permissions before doing so, and taking it requires
`SeTakeOwnershipPrivilege` to be enabled in the process token — which PowerShell does not do on
its own. This is why a plain `Set-Acl` fails with *"Requested registry access is not allowed"*
even from an elevated prompt, and why the tool enables the privilege through `AdjustTokenPrivileges`
before touching the ACL.

---

## 6. Result

Verified across multiple reboots on the affected machine:

- The effects chain stays as THX configured it
- The Realtek service remains in **Automatic** and starts normally
- Realtek onboard audio keeps all of its effects
- Synapse and THX configure the headset without any error

After a reboot the service still creates its CAPX context on the endpoint and writes metadata
into it — `{c4f6b0fa-...},0/,2/,2000/,3` and `{88d5b221-...},83` in the `User` store, with
`Default` left empty — but it can no longer touch `,13`, `,14`, `,19` or `,20`. The denial is
scoped exactly to the properties that matter.

---

## 7. Open questions

- **What the internal condition is.** Process Monitor records operations, not branches. The
  capture shows no lookup between the read and the write, which rules out the reachable
  candidates but does not reveal what the binary evaluates in memory.
- **Why the trigger is a reinstall.** The endpoint GUID changes when Synapse recreates the
  device, so the affected endpoint is a new one each time. Whether the previous GUID had
  something that exempted it, or whether the behaviour simply predates the reinstall and went
  unnoticed, was not established.
- **How widespread it is.** Reports of the same pattern go back to 2022 on Razer's community
  forum, on hardware with Realtek codecs. The mechanism is not brand-specific.
