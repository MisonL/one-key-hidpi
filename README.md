# Intel HiDPI for macOS

[English](README.md) | [中文](README-zh.md)

This fork supports one Intel-safe HiDPI workflow. It reads a connected
display's EDID, generates a bounded set of 2x HiDPI candidates, and can merge
those candidates into the display's override only after explicit confirmation.
It is not a replacement for BetterDisplay's flexible live scaling or GUI.

## Requirements

- Use a complete local checkout. The repository root must contain `hidpi.sh`,
  `intel-hidpi.sh`, and the complete `lib/` directory.
- Use a connected display that exposes a valid EDID through `ioreg`.
- Do not use a downloaded single script. The safe entrypoint refuses an
  incomplete checkout instead of looking for helper files elsewhere.
- The entrypoint and direct Intel tool reject symbolic links for their helper
  files and `lib/` directory, so they do not load a dependency from another
  location.

When more than one valid display record is present, the entrypoint prints its
vendor ID, product ID, and native resolution and requires an explicit choice.
The EDID, identifiers, and native resolution are kept in one record. Different
EDIDs that map to the same override target are rejected because that target
cannot be selected safely.

## Inventory

Inspect EDID-derived metadata and existing override modes without writing a
file:

```bash
./intel-hidpi.sh inventory
```

The command reports valid display records, their native resolutions, and the
matching override path. It fails explicitly when no valid EDID is available.

## Interactive Entry Point

Preview generated modes and cancel without changing an override:

```bash
./hidpi.sh
```

The local menu offers `preset` compatibility modes and a denser `smooth` mode
set. `smooth` uses the native display aspect ratio from two-thirds of native
through native size, with no more than 41 candidates. You may explicitly add a
near-native compatibility mode when it is appropriate for the selected panel.
Panels whose integer geometry cannot provide at least two exact-aspect-ratio
candidates in that range are rejected by `smooth`; use `preset` for those
panels.
For an explicit BetterDisplay-compatible set, `smooth` can also add two ordinary
resolution payloads for every HiDPI candidate: the logical resolution and its
2x framebuffer resolution. This option is intended for compatibility with the
observed BetterDisplay override layout, not as a claim of flexible live scaling.
Ordinary payload dimensions are encoded as unsigned 32-bit fields. The generator
explicitly rejects non-positive values, leading zeros, values above
`4294967295`, and a candidate whose logical and framebuffer payloads are identical.
When applying a previewed selection, pass the same `--mode-set`,
`--include-near-native`, and `--include-similar-resolutions` options to `apply`;
a different selection intentionally produces a different candidate set.

Applying or reverting requires a root invocation and the exact `APPLY` or
`REVERT` confirmation word:

```bash
sudo ./hidpi.sh
```

The menu does not elevate privileges by itself. It never falls back to the
removed direct generator, remote download, or broad cleanup paths.
The tool does not reload display services, reinitialize the display subsystem,
reboot, or hot-plug displays. Static validation does not prove that macOS has
accepted and exposed every candidate mode at runtime.

## Command Line

Generate candidates without writing an override:

```bash
./intel-hidpi.sh preview --native-resolution 1920x1080 --mode-set smooth \
  --include-near-native --include-similar-resolutions
```

Verify the selected override's payload set in a read-only operation:

```bash
./intel-hidpi.sh verify-override --vendor-id <vendor-id> --product-id <product-id> \
  --native-resolution <width>x<height> --mode-set smooth --include-near-native \
  --include-similar-resolutions
```

`verify-override` checks the unique direct `scale-resolutions` data payload
set in the target plist. It returns `0` only when that set matches exactly,
reports duplicate direct data entries separately, and returns `2` when there
are missing or extra payloads.

Verify the modes that CoreGraphics actually exposes for the selected display in
a separate read-only operation:

```bash
./intel-hidpi.sh verify-modes --vendor-id <vendor-id> --product-id <product-id> \
  --native-resolution <width>x<height> --mode-set smooth --include-near-native \
  --include-similar-resolutions
```

`verify-modes` compares both logical dimensions and framebuffer dimensions. The
ordinary similar-resolution records intentionally use identical logical and
framebuffer dimensions. It returns `0` for a complete result and `2` when some
generated modes are missing. With `--modes-file`, it validates an offline
capture only; that result is not evidence of the current display state.

The two checks answer different questions. A passing `verify-override` proves
the override payload configuration, not that macOS accepted every payload as a
live mode. A passing `verify-modes` proves the enumerated mode pairs, not that
they came from this override file.

## Recovery

Revert only an override previously recorded by this tool for the selected
vendor and product ID:

```bash
sudo ./intel-hidpi.sh revert --vendor-id <vendor-id> --product-id <product-id> --confirm
```

The command checks its manifest, target content, and override root before it
restores or removes anything. It stops when the recorded state is missing or
has changed outside the tool.

## Limits

EDID override behavior depends on the display, graphics driver, and macOS.
Deterministic preview and fixture validation do not prove that a particular
Intel Hackintosh configuration will expose every candidate at runtime.

## Inspired By

https://www.tonymacx86.com/threads/solved-black-screen-with-gtx-1070-lg-ultrafine-5k-sierra-10-12-4.219872/page-4#post-1644805

https://github.com/syscl/Enable-HiDPI-OSX
