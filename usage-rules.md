<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# BB.Camera.Libcamera Usage Rules

`bb_camera_libcamera` provides `BB.Camera.Libcamera`, a camera driver for
Raspberry Pi CSI cameras for [Beam Bots](https://hexdocs.pm/bb). It captures
MJPEG from libcamera through a supervised `rpicam-vid` process and serves
frames through `bb_camera`. For framework basics see `bb`'s rules; for the
consumer-facing API see `bb_camera`'s. This file covers only what is specific
to this driver.

## Core principles

1. **One sensor per camera.** A Pi 5 with two cameras is two `sensor`
   declarations, each with its own `:camera`. Two sensors naming the same
   camera do not share it: the second fails to capture.
2. **Name cameras by id when there is more than one.** The id is the
   connector; an index is a position in a list that shifts when a camera
   fails to probe.
3. **You never start or stop capture.** `bb_camera` refcounts consumers and
   tells the driver. One `rpicam-vid` serves every consumer of a camera.
4. **Frames do not go on pubsub.** The robot's topic carries capture lifecycle
   and periodic capture state only.

## Wiring it in

One camera:

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.Libcamera, camera: 0, width: 1280, height: 720}
  end
end
```

Two, by id, with buffers lowered so both fit in CMA:

```elixir
topology do
  link :head do
    sensor :left_eye, {BB.Camera.Libcamera,
      camera: "/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10",
      width: 1280, height: 720, buffer_count: 2}

    sensor :right_eye, {BB.Camera.Libcamera,
      camera: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10",
      width: 1280, height: 720, buffer_count: 2}
  end
end
```

Find ids on the Pi with `BB.Camera.Libcamera.Devices.list()` in IEx or
`rpicam-vid --list-cameras` in a shell. Do not copy the ids above: they are a
Pi 5's, and other boards' device-tree paths differ.

## Options

| Option | Default | |
|---|---|---|
| `:camera` | `0` | Index, or libcamera id |
| `:width`, `:height` | `640`, `480` | What to ask for; frames report what was produced |
| `:frame_rate` | `30` | Hertz unit, number, or `{numerator, denominator}` |
| `:quality` | `50` | JPEG quality, 1 to 100 |
| `:hflip`, `:vflip` | `false` | Both for a camera mounted upside down |
| `:buffer_count` | `rpicam-vid`'s | Lower to fit several cameras in CMA |
| `:rpicam_vid` | `$PATH` | Executable path; `libcamera-vid` on older systems |

The remaining options are capture bounds shared with `bb_camera_v4l`; see
`BB.Camera.Libcamera.options_schema/0`.

## Failure modes

- **Camera busy, missing, or out of CMA** — `rpicam-vid` exits 255 within
  about 100 ms, and the hub publishes `EndCapture{reason: :error}` with
  `{:shutdown, {:exited, 255}}`. The console says which: `Device or resource
  busy`, or `dmaHeap allocation failure`.
- **Unknown camera id** — capture fails with
  `{:unknown_camera, id, known_ids}` before anything is started. The known ids
  are the ones to choose from.
- **Capture is not retried.** Reopening is the consumer's decision, taken by
  subscribing again.

## Anti-patterns

- **Indices on a multi-camera board.** If one camera fails to probe, the other
  takes its index, and the robot silently sees through the wrong eye.
- **Two sensors on one camera.** libcamera lets one process hold a camera; the
  second sensor fails every capture. Share a camera by consuming one sensor
  from several places instead.
- **Raising frame size on two cameras without checking CMA.** The second
  camera fails with status 255. Lower `:buffer_count` or give the kernel more
  CMA.
- **Pairing two cameras' frames by timestamp.** Stamps are arrival times in
  the BEAM, not exposure times.
- **Declaring a parameter looser than the option it feeds.** `-1` stored for
  `:width` stops the camera, and `handle_options/2` cannot refuse it.
- **Starting a `BB.Camera.FFmpeg.Capture` for a camera this driver declares.**
  The driver owns its capture.

## Further reading

- [bb_camera_libcamera docs](https://hexdocs.pm/bb_camera_libcamera)
- `BB.Camera.Libcamera` for the options
- `BB.Camera.Libcamera.Devices` for camera ids
- `bb_camera`'s usage rules for the hub, subscriptions and frames
- `bb_camera_ffmpeg`'s usage rules for the capture this driver runs
