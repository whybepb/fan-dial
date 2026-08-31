# FanDial

A macOS menu bar app that controls your Mac's fans with a rotary dial —
rotate the ring, the ticks fill up, the fans spin faster. Built for
Apple Silicon (tested on a MacBook Pro M4 Pro), talks straight to the SMC.

> **Use at your own risk.** This forces fan speeds through a diagnostic
> firmware path and requires root for writes. Targets are clamped to the
> SMC's own min–max envelope and auto mode is always one click away, but
> it's your machine and your thermals.

```
fan-dial/
├── shared/SMCCore.swift   SMC client (IOKit) + fan model — used by both targets
├── cli/main.swift         fanctl: status / set <rpm> / max / auto / keys
├── app/                   SwiftUI menu bar app (MenuBarExtra + the dial)
├── build.sh               builds fanctl and FanDial.app (no Xcode project needed)
└── install-helper.sh      optional: setuid fanctl → no password prompts
```

## Build & run

```sh
./build.sh
open FanDial.app
```

A fan icon appears in the menu bar (filled while manual). Click it:

- **Drag the ring** — sets a manual target RPM (clamped to the SMC's own
  min–max envelope, 2317–7826 on the M4 Pro). Applied on release; moves made
  while a slow apply is in flight are coalesced, latest wins.
- **Tap the center** — releases manual back to auto (tap does nothing when
  already auto — engaging manual costs a multi-second unlock).
- **Auto pill** — hands the fans back to macOS's automatic curve.
- **Max pill** — full send.
- **CPU/GPU temps** — averaged die sensors, shown under the dial.
- **login** — start FanDial at login (SMAppService).

Manual control is *held*: sleep/wake resets the firmware's unlock flag, so
FanDial watches for wake and quietly re-engages your chosen RPM (silent-helper
installs only; it backs off and reverts to auto if macOS keeps reclaiming).
Quitting FanDial hands the fans back to macOS automatically.

Reading RPM needs no privileges. *Writing* a target requires root, so on
every change the app runs `fanctl` through macOS's admin-authorization
dialog (the OS collects your password/Touch ID — the app never sees it).

## Skipping the password prompt (optional)

Click **"Stop asking for my password"** in the popover (one admin dialog), or:

```sh
sudo ./install-helper.sh
```

Installs `/usr/local/bin/fanctl` setuid-root; FanDial detects it and applies
changes silently. It only accepts `status|set|max|auto` and clamps to the
SMC envelope, but it *is* a setuid binary — skip if that bothers you.
Remove with `sudo rm /usr/local/bin/fanctl`.

## CLI

```sh
./fanctl status          # read fans + die temps (no root)
./fanctl temp            # CPU/GPU die temperatures (no root)
sudo ./fanctl set 4000   # force both fans to 4000 rpm
sudo ./fanctl auto       # back to automatic
sudo ./fanctl probe      # test which fan keys accept writes (no state change)
./fanctl keys            # dump F* SMC keys (debug)
```

(Drop the `sudo` once the setuid helper is installed — `/usr/local/bin/fanctl`
runs privileged on its own.)

## M3/M4: the thermal-manager unlock (why writes used to fail with 0x82)

From the M3 generation on, `thermalmonitord` holds the fan keys and the firmware
rejects `F0Md`/`F0Tg` writes with SMC result `0x82` (bad command). The unlock,
documented by [agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan)
and implemented in [raminsharifi/MacFanControl](https://github.com/raminsharifi/MacFanControl):

1. try `F0Md = 1`; on `0x82`, write `Ftst = 1` (diagnostic flag), wait ~3 s
2. retry the mode write (100 ms interval; yields in ~3–6 s, longer under load)
3. then write `F0Tg`; keep `Ftst = 1` while manual
4. restore: `F0Md = 0` per fan, then `Ftst = 0` — releasing `Ftst` lets
   thermalmonitord reclaim the fans even if a mode write is refused

Consequences: the *first* manual engage takes a few seconds; sleep/wake resets
`Ftst`, so a manual setting reverts to automatic on wake (FanDial re-engages it
for you — see above); under heavy thermal load the manager may refuse to yield
at all. Mode values: 0 = classic auto, 1 = manual, 3 = thermalmonitord system
control (the normal modern state — thermalmonitord polls ~4 s idle / ~250 ms
under load and reclaims manual mode unless `Ftst` stays 1). On M5+ the mode
key is lowercase (`F0md`) with no `Ftst` gate — FanDial handles both.

Measured on an M4 Pro: cold engage ~1–4 s (polled), warm adjustments ~0.15 s,
auto release ~10 ms. Manual mode holds indefinitely while awake with `Ftst` held.

## Notes & safety

- Don't run FanDial and **Macs Fan Control** (or similar) at the same time —
  two writers fighting over `F0Tg` gives confusing results. Quit one.
- Targets are always clamped to the SMC's reported `[F0Mn, F0Mx]`, and Auto
  is one click away. Forcing fans *low* under heavy load makes the machine
  throttle sooner; the dial's floor is the SMC minimum, not zero.
- `SMCParamStruct` in `SMCCore.swift` must stay exactly 80 bytes (kernel ABI).
  Swift packs nested structs tighter than C, hence the explicit `_pad` fields.
- The toolchain currently stamps binaries with a min-OS newer than the host
  unless you pass an explicit `-target` — `build.sh` pins `arm64-apple-macos14.0`.

## Credits

The M3+/M4 thermal-manager unlock (`Ftst`) is documented research by
[agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) and
implemented in [raminsharifi/MacFanControl](https://github.com/raminsharifi/MacFanControl) —
FanDial's unlock sequence follows their findings. Temperature sensor key sets
come from [narugit/smctemp](https://github.com/narugit/smctemp). The SMC
user-client protocol descends from [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl)
and the wider open-source SMC lineage.

MIT licensed. Built by [@whybepb](https://github.com/whybepb).
