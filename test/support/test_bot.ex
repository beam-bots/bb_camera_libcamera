# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.Test.StubBot do
  @moduledoc """
  A two-camera robot whose captures are driven by
  `BB.Camera.FFmpeg.Test.StubBackend`.

  Everything but the bytes is real: the real driver, the real hub, the real
  framer and the real capture bounds. Only the thing that would have been
  `rpicam-vid` is replaced, so a test can decide exactly what each camera
  produces and when.

  `:eye` is chosen by index, and its width comes from a parameter so a test
  can reconfigure it the way a robot actually does. `:right` is chosen by
  libcamera id, which the driver resolves by running `fake_rpicam_vid
  --list-cameras` - a script replaying a real Pi 5's listing. `:ghost` names
  an id that listing doesn't have.

  The stub reports to whatever process is registered as
  `:bb_camera_libcamera_stub_observer`, because the DSL is compiled long
  before any test process exists.
  """

  use BB

  @fake_rpicam_vid Path.expand("fake_rpicam_vid", __DIR__)

  settings do
    name(:bb_camera_libcamera_stub_bot)
  end

  parameters do
    group :camera do
      param(:width, type: :integer, default: 640)
    end
  end

  topology do
    link :head do
      sensor(
        :eye,
        {BB.Camera.Libcamera,
         camera: 0,
         width: param([:camera, :width]),
         height: 480,
         frame_rate: 30,
         rpicam_vid: @fake_rpicam_vid,
         backend: BB.Camera.FFmpeg.Test.StubBackend,
         backend_opts: [report_to: :bb_camera_libcamera_stub_observer]}
      )

      sensor(
        :right,
        {BB.Camera.Libcamera,
         camera: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10",
         width: 1280,
         height: 720,
         rpicam_vid: @fake_rpicam_vid,
         backend: BB.Camera.FFmpeg.Test.StubBackend,
         backend_opts: [report_to: :bb_camera_libcamera_stub_observer]}
      )

      sensor(
        :ghost,
        {BB.Camera.Libcamera,
         camera: "/base/axi/pcie@1000120000/rp1/i2c@70000/imx708@1a",
         rpicam_vid: @fake_rpicam_vid,
         backend: BB.Camera.FFmpeg.Test.StubBackend,
         backend_opts: [report_to: :bb_camera_libcamera_stub_observer]}
      )
    end
  end
end
