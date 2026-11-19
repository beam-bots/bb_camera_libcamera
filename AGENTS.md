<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this
repository.

## Project Overview

`bb_camera_libcamera` is a Beam Bots camera driver for Raspberry Pi cameras.
One module, `BB.Camera.Libcamera`, is both a `BB.Sensor` and a `BB.Camera`. It
runs `rpicam-vid --codec mjpeg --output -` and reads the JPEGs off its stdout.

Running the process, flow control, JPEG framing and teardown live in
`bb_camera_ffmpeg`, shared with `bb_camera_v4l` and `bb_camera_avf`. That
package's `Capture` runs any executable that writes concatenated JPEGs to
stdout; nothing in it is specific to ffmpeg except `Backend.MuonTrap`'s
`-nostdin` check, which is why this package has a backend of its own.

Capture lifecycle is **not** this package's decision. `bb_camera`'s
`BB.Camera.Hub` refcounts consumers and tells the driver when to start and
stop, so there is one capture per camera no matter how many consumers there
are. Do not add a second path that starts capture.

## Build and Test Commands

```bash
BB_VERSION=local mix check --no-retry        # everything
BB_VERSION=local mix test                    # no camera and no rpicam-vid needed
BB_VERSION=local mix test --include rpicam   # on a Pi with a camera attached
```

`BB_VERSION=local` resolves `bb`, `bb_camera` and `bb_camera_ffmpeg` from the
sibling checkouts.

## Architecture

| Module | |
|---|---|
| `BB.Camera.Libcamera` | The driver. Options, lifecycle, and the bridge to `BB.Camera.Hub` |
| `BB.Camera.Libcamera.Command` | Builds and validates the `rpicam-vid` argument vector. Pure |
| `BB.Camera.Libcamera.Devices` | Lists cameras via `rpicam-vid --list-cameras`; resolves an id to an index |
| `BB.Camera.Libcamera.Backend` | `rpicam-vid` under MuonTrap. Delegates all but `open/3` to `bb_camera_ffmpeg` |

## Why rpicam-vid, and not libcamera directly

libcamera is a C++ library. Talking to it from the BEAM directly means a NIF
or a port program in C++, cross-compiled against the target's libcamera, with
its own ISP tuning, buffer management and JPEG encoder. `rpicam-vid` is all of
that, written and maintained by Raspberry Pi, and ships wherever libcamera
does on a Pi — Raspberry Pi OS and the Nerves systems that enable rpicam-apps.
Running it as a subprocess also puts a process boundary between a crashing
camera stack and the VM.

What that costs: timestamps are arrival times (the MJPEG stream carries none),
camera controls are whatever `rpicam-vid` exposes as flags, and every option
change restarts the process. A port program would be the answer to any of
those becoming a requirement.

## Things that are easy to get wrong

**Measured on a Pi 5 under Nerves with two imx219s**, rpicam-apps 1.7.0 and
libcamera 0.5.0. These are facts, not guesses; re-measure before contradicting
them.

**rpicam-vid does not read stdin**, so MuonTrap's acknowledgements reach
MuonTrap. Through a 16 KiB `:stdio_window`, 170 KB of frames arrived, which
needs every acknowledgement to have got through. `rpicam-vid` reads stdin only
with `--keypress`. Never pass it.

**There is no `-nostdin`, and `Backend.MuonTrap` refuses argv without it.**
`rpicam-vid` rejects unknown flags, so the flag cannot be smuggled in. That
check is the whole reason `BB.Camera.Libcamera.Backend` exists; it delegates
`ack/2`, `request_stop/1` and `close/1` unchanged. If `bb_camera_ffmpeg` ever
moves the check out of its backend, delete this one.

**`--camera` takes an index, and only the listing knows what it means.** Two
identical sensors on a Pi 5 differ only in their libcamera id, which is the
device-tree path of the connector (`.../i2c@88000/...` and
`.../i2c@80000/...`). Index 0 was `i2c@88000`: the order is libcamera's, not
lexical. An id is resolved against a fresh `--list-cameras` at the start of
every capture, by the same executable that will capture, and never cached.
Listing takes 45–120 ms and works while other cameras are capturing; a busy
camera's modes read as `65535x65535`, which is why modes are not parsed.

**Two cameras compete for CMA.** On 64 MiB of CMA, two 1280x720 captures with
default buffers fail: the second `rpicam-vid` exits 255 with `dmaHeap
allocation failure`. `buffer_count: 2` fits them, at 30 fps each. 640x480
fits with defaults. This is a board configuration limit, not a driver bug, and
the driver's job is to report it as `CaptureFailed`, which it does.

**A busy or missing camera exits 255 quickly** — within about 100 ms — rather
than hanging, so `:start_timeout_ms` is a backstop here, not the main path.
A second sensor declared on a camera another one is capturing fails this way
and leaves the first capturing.

**SIGTERM stops rpicam-vid within 10 ms**, and closing the port leaves nothing
running. MuonTrap is still the mechanism; see `bb_camera_ffmpeg`'s AGENTS.md
before changing anything about process lifetime.

**libcamera logs at INFO to stderr.** `--verbose 0` silences `rpicam-vid` but
not libcamera, so the backend sets `LIBCAMERA_LOG_LEVELS=*:WARN`. Leave
warnings on: `dmaHeap allocation failure` and `Device or resource busy` are
the only explanation a user gets.

**`--flush` is not optional.** Without it frames sit in stdio's buffer and
arrive in lumps.

**`--framerate` takes a decimal**, not ffmpeg's `num/den`. `Command` converts
the exact rational to a float at the last moment.

**Capture is confirmed on the first whole image**, not on `rpicam-vid`
starting, and stop and start are a sequence. Both work exactly as in
`bb_camera_v4l`, whose AGENTS.md explains why.

**The sensor traps exits.** A camera that cannot be opened is ordinary, and
the hub has an event for saying so.

**`stream_info/1` must stay pure.** Discovery calls it against robots that are
not running. It must not list cameras.

## The lifecycle is the third copy

From `init/1` down, `BB.Camera.Libcamera` is the same state machine as
`BB.Camera.V4L` and `BB.Camera.AVF`: `request_start`, `begin_stop`,
`run_pending`, `abandon_pending`, `confirm`, `deliver`, `next_sequence`. Only
`start_capture` differs, by resolving the camera first. It was copied rather
than extracted so this package could ship against released versions of its
siblings. Keep it textually close to the other two, so that extracting it into
`bb_camera_ffmpeg` stays mechanical — and a fix to one of the three almost
certainly belongs in all of them.

## Testing

The test robot declares `BB.Camera.FFmpeg.Test.StubBackend` as its backend,
and tests feed it images from `BB.Camera.FFmpeg.Test.JpegBuilder`. Both ship
in `bb_camera_ffmpeg`'s `lib` for exactly this.

Camera ids are resolved against `test/support/fake_rpicam_vid`, a shell script
replaying a real Pi 5's `--list-cameras` output — with the first camera busy,
so its modes are the unreadable kind. It is a real subprocess, but answers
immediately and deterministically.

**No test sleeps, and no timed negative assertions.** To show something did
not happen, push a synchronous call through the process first and then use
`refute_received`.

Tests tagged `:rpicam` need a Pi with `rpicam-vid` and a camera, and are
excluded by default. On Nerves, where there is no `mix test`, the same checks
can be run by loading the compiled `.beam`s and driving a robot from IEx.

Every test logs `Topology supervisor ... has stopped - force-disarming` at
teardown. That is `bb`'s safety controller on any robot stopping, not this
driver; a robot with no sensors does the same.

## Dependencies

- `bb` — the framework
- `bb_camera` — the `BB.Camera` behaviour, hub, frame and error types
- `bb_camera_ffmpeg` — process supervision under MuonTrap, flow control and
  JPEG framing (not ffmpeg itself, which this driver never runs)

## Licensing headers

Every source file must carry an SPDX header — a `#`-style comment for code, an
HTML comment for Markdown, or a `<file>.license` sidecar for files that can't
hold comments. `mix check` runs `reuse lint` and fails the build if one is
missing.

When you create a new file, its `SPDX-FileCopyrightText` line must credit **the
user you are working for** — not you (the agent), and not this repo's original
author. Take their name from `git config user.name` and use the current year.
