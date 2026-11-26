<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# bb_camera_libcamera

[![CI](https://github.com/beam-bots/bb_camera_libcamera/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/bb_camera_libcamera/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/bb_camera_libcamera.svg)](https://hex.pm/packages/bb_camera_libcamera)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/bb_camera_libcamera)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/bb_camera_libcamera)](https://api.reuse.software/info/github.com/beam-bots/bb_camera_libcamera)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/beam-bots/bb_camera_libcamera)

A [Beam Bots](https://github.com/beam-bots/bb) camera driver for Raspberry Pi
cameras — the CSI ribbon-cable kind — capturing raw `:I420` frames from
libcamera through a supervised `rpicam-vid` process. Boards with more than one camera connector,
such as the Pi 5, are supported: declare one sensor per camera.

It is a `BB.Sensor` and a `BB.Camera`, declared like any other sensor:

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.Libcamera, camera: 0, width: 1280, height: 720}
  end
end
```

Consumers go through [`bb_camera`](https://github.com/beam-bots/bb_camera),
which shares one capture between all of them. Two browser tabs previewing the
same camera produce one `rpicam-vid`, not two.

**Frames never travel on the robot's pubsub.** That carries capture lifecycle
only — `BeginCapture` and `EndCapture`. Frame bytes go over `bb_camera`'s
bounded media interface.

## Installation

```elixir
def deps do
  [
    {:bb, "~> 0.33"},
    {:bb_camera, "~> 0.1"},
    {:bb_camera_libcamera, "~> 0.1"}
  ]
end
```

Working on this driver from a `bb_workspace` checkout instead? `BB_VERSION=local`
resolves `bb`, `bb_camera` and `bb_camera_ffmpeg` from the sibling checkouts
rather than from Hex.

## Requirements

- **`rpicam-vid`** on `$PATH`, from `rpicam-apps`. Raspberry Pi OS ships it
  (older releases call it `libcamera-vid`; pass that path as `:rpicam_vid`).
  A Nerves system needs libcamera and rpicam-apps in its Buildroot
  configuration.
- **A camera the Pi has detected at boot.** `rpicam-vid --list-cameras` is
  the check: if a camera is not listed there, nothing here can open it.
- **A C compiler at build time**, for MuonTrap's wrapper program — see
  [`bb_camera_ffmpeg`](https://github.com/beam-bots/bb_camera_ffmpeg). Nerves
  toolchains have one.
- **Not ffmpeg.** This driver uses `bb_camera_ffmpeg` for its capture
  machinery — MuonTrap, flow control, framing — but never runs ffmpeg.

## Frame sizes: width a multiple of 128

Frames are `{:raw, :I420}` at exactly the configured width and height. The
width must be a **multiple of 128** and the height **even**; anything else is
refused when the sensor starts (or when a parameter changes it) with
`BB.Error.Invalid.Camera.UnsupportedFormat`, reason `:invalid_dimensions`.

The reason is row padding. `rpicam-vid --codec yuv420` writes each of the
ISP's buffers whole, padding included, and never says how much padding there
is. The Pi 4's ISP pads each luma row to a multiple of 64 bytes and the Pi
5's to a multiple of 128, so only at widths that are already a multiple of
128 is a frame tightly packed `:I420` — which is what `bb_camera` carries,
and the only thing the stream can be cut into frames by without a marker to
find. 640, 1280 and 1920 work; 800 does not.

The YUV is full-range BT.601 (sYCC): `rpicam-vid` uses the JPEG colour space
for this codec, not the limited range most video uses.

## Choosing a camera

`:camera` takes an index or a libcamera camera id. From IEx on the Pi:

```elixir
BB.Camera.Libcamera.Devices.list()
#=> {:ok,
#=>  [
#=>    %{index: 0, model: "imx219", description: "3280x2464 10-bit RGGB",
#=>      id: "/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10"},
#=>    %{index: 1, model: "imx219", description: "3280x2464 10-bit RGGB",
#=>      id: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10"}
#=>  ]}
```

or `rpicam-vid --list-cameras` from a shell, which also prints each sensor's
modes.

The id is the sensor's device-tree path, so it names the **connector** the
camera is plugged into. That is the only thing telling two identical cameras
apart, and it does not move. An index does: it is a position in that list, and
a camera that fails to probe at boot shifts the ones after it. With one camera,
`camera: 0` is fine. With two, use ids:

```elixir
link :head do
  sensor :left_eye, {BB.Camera.Libcamera,
    camera: "/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10",
    width: 1280, height: 720, buffer_count: 2}

  sensor :right_eye, {BB.Camera.Libcamera,
    camera: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10",
    width: 1280, height: 720, buffer_count: 2}
end
```

To find out which connector is which, cover one lens and look at the frames.

An id is resolved to an index by listing the cameras afresh at the start of
every capture, which takes about a tenth of a second.

## Two cameras and CMA

Each camera's frame buffers come from the kernel's contiguous memory pool
(CMA). With too little of it, the second camera to start fails — `rpicam-vid`
exits with status 255 and prints this on the console:

```
dmaHeap allocation failure for rpicam-apps5
ERROR: *** failed to allocate capture buffers for stream ***
```

Measured on a Pi 5 under Nerves with 64 MiB of CMA and two imx219s:

| Each camera | `buffer_count` | Both capture? |
|---|---|---|
| 640x480 | default | yes |
| 1280x720 | default | **no** — the second fails |
| 1280x720 | `2` | yes, 30 fps each |

`buffer_count: 2` costs headroom: with fewer buffers, a frame `rpicam-vid` is
late writing out is a frame dropped. Raw output doesn't change any of this:
the ISP's YUV buffers are allocated whatever `rpicam-vid` does with them. The other fix is more CMA — check
`CmaTotal` in `/proc/meminfo`, and raise it with the `cma=` kernel argument or
the `cma-` parameter of the `vc4-kms-v3d` overlay, whichever your system uses.

## Smoke test on a Pi

From IEx on the Pi, with the package loaded:

```elixir
defmodule PiCam do
  use BB

  settings do
    name :pi_cam
  end

  topology do
    link :head do
      sensor :eye, {BB.Camera.Libcamera, camera: 0, width: 1280, height: 720}
    end
  end
end

{:ok, _pid} = PiCam.start_link([])

BB.subscribe(PiCam, [:sensor, :head, :eye])

{:ok, session} = BB.Camera.Media.open(PiCam, :eye, format: {:raw, :I420})
{:ok, frame} = BB.Camera.Media.next(session, 10_000)

{frame.format, frame.width, frame.height, byte_size(frame.data)}
#=> {{:raw, :I420}, 1280, 720, 1382400}

File.write!("/tmp/camera.yuv", frame.data)

BB.Camera.Media.close(session)
flush()
#=> {:bb, [:sensor, :head, :eye], %BB.Message{payload: %BB.Message.Camera.BeginCapture{...}}}
#=> {:bb, [:sensor, :head, :eye], %BB.Message{payload: %BB.Message.Camera.EndCapture{reason: :no_subscribers, ...}}}
```

Copy `/tmp/camera.yuv` somewhere with ffmpeg and look at it with
`ffplay -f rawvideo -pixel_format yuvj420p -video_size 1280x720 camera.yuv`.

`System.cmd("ps", [])` while the session is open shows one `rpicam-vid` per
capturing camera, however many consumers there are, and none once the last
consumer has closed.

## Options

| Option | Default | |
|---|---|---|
| `:camera` | `0` | Index or libcamera id, as `Devices.list/1` reports them |
| `:width`, `:height` | `640`, `480` | Width a multiple of 128, height even. libcamera picks a sensor mode and the ISP scales |
| `:frame_rate` | `30` | A hertz unit, a number, or `{numerator, denominator}` |
| `:hflip`, `:vflip` | `false` | Mirror the image. Both together for a camera mounted upside down |
| `:buffer_count` | `rpicam-vid`'s | Frame buffers to allocate. Lower it to fit several cameras in CMA |
| `:rpicam_vid` | `$PATH` | Path to the `rpicam-vid` executable |
| `:drop_queue_len` | `8` | Shed frames while more reads than this are waiting |
| `:stdio_window` | 256 KiB | Bytes of output `rpicam-vid` may have in flight unacknowledged |
| `:start_timeout_ms` | `10000` | Fail capture when no frame has arrived by then |
| `:stop_timeout_ms` | `2000` | How long `rpicam-vid` gets after `SIGTERM` before `SIGKILL` |

## How it holds together

```
MuonTrap ──> rpicam-vid ──pipe──> Capture ──frames──> BB.Camera.Hub ──> consumers
                                                            │
                                                            └─ lifecycle ──> BB.PubSub
```

- **`BB.Camera.Libcamera.Command`** builds the `rpicam-vid` argument vector
  and validates it. No shell ever parses it.
- **`BB.Camera.Libcamera.Devices`** lists cameras and resolves an id to the
  index `rpicam-vid` wants.
- **`BB.Camera.Libcamera.Backend`** runs `rpicam-vid` under MuonTrap.
- **[`bb_camera_ffmpeg`](https://github.com/beam-bots/bb_camera_ffmpeg)**'s
  `Capture` does the rest, as it does for `bb_camera_v4l` and
  `bb_camera_avf`: flow control, cutting the stream into frames by size,
  holding the first frame until
  the hub has been told capture started, and confirming teardown.

## Measured on a Pi 5

Two imx219s under Nerves, both at 1280x720 and 30 fps with `buffer_count: 2`,
when this driver still captured MJPEG:

- first frame from both cameras within 0.8 s of the consumers opening;
- 30 fps sustained from each;
- about 17% of one core per `rpicam-vid`, which was libjpeg encoding every
  frame — the cost raw output removes;
- `rpicam-vid` exits within 10 ms of `SIGTERM`, and nothing is left running
  after the last consumer closes.

Raw output has not been re-measured. It trades that encode for volume: a
1280x720 `:I420` frame is 1.3 MiB, so 30 fps is about 40 MiB/s through the
pipe per camera, where MJPEG was well under 1 MiB/s.

## Limitations

- **Raspberry Pi only**, in practice: `rpicam-vid` is built for the Pi's
  camera stack. A USB webcam on a Pi wants `bb_camera_v4l`.
- **Width must be a multiple of 128, height even** — see
  [Frame sizes](#frame-sizes-width-a-multiple-of-128).
- **Timestamps are arrival times, not exposure times, and are not suitable for
  synchronisation.** The raw stream on `rpicam-vid`'s stdout carries no
  timestamps; a frame is stamped when the read completing it reached the BEAM.
  Two cameras' frames cannot be paired by these stamps.
- **The frame rate is reported as requested.** What the frames actually did is
  measured by `BB.Camera.Hub` and published in `BB.Message.Camera.CaptureState`.
- **No camera controls** beyond what is here: exposure, gain, white balance and
  the rest are left to libcamera's automatic algorithms.
- **A failed capture is not retried.** Reopening is the consumer's decision,
  taken by subscribing again.
- **Changing an option that reaches `rpicam-vid` restarts it**, with
  `EndCapture` and `BeginCapture` around the change.
- **`rpicam-vid`'s diagnostics go to the VM's console**, not into the error.
  libcamera's own logging is held at `WARN`; see
  `BB.Camera.Libcamera.Backend`.

## Testing

```sh
BB_VERSION=local mix deps.get
BB_VERSION=local mix test                   # no camera, no rpicam-vid needed
BB_VERSION=local mix test --include rpicam  # on a Pi with a camera attached
BB_VERSION=local mix check --no-retry
```

The default suite drives the driver through `bb_camera_ffmpeg`'s stub backend,
and resolves camera ids against `test/support/fake_rpicam_vid`, which replays
a real Pi 5's camera listing. No test sleeps.

## Licence

Apache-2.0. See `LICENSES/`.
