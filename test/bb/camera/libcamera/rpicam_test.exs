# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.RpicamTest do
  @moduledoc """
  The tests that run this driver's `rpicam-vid` command against a real camera.

  The stubbed suite proves the driver's behaviour, and `bb_camera_ffmpeg`
  proves that capture under MuonTrap leaves nothing behind. Neither proves that
  the argument vector built here is one `rpicam-vid` accepts and turns into
  JPEGs, or that `BB.Camera.Libcamera.Backend` gets them out. These do.

  Tagged `:rpicam` and excluded by default: they need a Raspberry Pi with
  `rpicam-vid` and at least one camera attached. Run them there with
  `mix test --include rpicam`.
  """
  use ExUnit.Case, async: false

  alias BB.Camera.FFmpeg.Capture
  alias BB.Camera.Libcamera.{Backend, Command, Devices}

  @moduletag :rpicam

  setup do
    unless System.find_executable("rpicam-vid") do
      flunk("rpicam-vid is not on $PATH")
    end

    {:ok, devices} = Devices.list()

    if devices == [] do
      flunk("rpicam-vid lists no cameras")
    end

    {:ok, devices: devices}
  end

  defp start_capture(id, index, command_opts) do
    test = self()
    {:ok, command} = Command.new(command_opts)

    sink = fn frame ->
      send(test, {:frame, id, frame})
      :ok
    end

    capture =
      start_supervised!(
        {Capture,
         executable: command.executable,
         args: Command.argv(command, index),
         backend: Backend,
         notify: test,
         sink: sink},
        id: id,
        restart: :temporary
      )

    :ok = Capture.go(capture)

    capture
  end

  test "the command produces JPEG frames of the size it asks for" do
    start_capture(:capture, 0, width: 640, height: 480, frame_rate: 10)

    # The bound is an upper limit on an event that must happen, not an
    # estimate of how long the camera takes to start.
    assert_receive {:frame, :capture, frame}, 20_000
    assert {frame.width, frame.height} == {640, 480}
    assert <<0xFF, 0xD8, _rest::binary>> = frame.data
  end

  test "every listed camera captures at the same time", %{devices: devices} do
    for device <- devices do
      start_capture(device.index, device.index,
        camera: device.id,
        width: 640,
        height: 480,
        frame_rate: 10,
        buffer_count: 2
      )
    end

    for device <- devices do
      index = device.index
      assert_receive {:frame, ^index, _frame}, 20_000
    end
  end

  test "a camera that does not exist fails rather than hanging", %{devices: devices} do
    capture = start_capture(:capture, length(devices), width: 320, height: 240, frame_rate: 10)

    Process.unlink(capture)
    monitor = Process.monitor(capture)

    assert_receive {:bb_camera_ffmpeg, ^capture, {:exited, status}}, 20_000
    assert status != 0
    assert_receive {:DOWN, ^monitor, :process, ^capture, {:shutdown, {:exited, ^status}}}
    refute_received {:frame, :capture, _frame}
  end
end
