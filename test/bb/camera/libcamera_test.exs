# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.LibcameraTest do
  @moduledoc false
  # The stub reports to a registered name, which is global.
  use ExUnit.Case, async: false

  alias BB.Camera.FFmpeg.Test.{JpegBuilder, StubBackend}
  alias BB.Camera.Libcamera
  alias BB.Camera.Libcamera.Test.StubBot
  alias BB.Camera.Media
  alias BB.Error.Invalid.Camera.UnknownStreamInfo
  alias BB.Message.Camera.{BeginCapture, EndCapture}

  @topic [:sensor, :head, :eye]

  setup do
    Process.register(self(), :bb_camera_libcamera_stub_observer)
    start_supervised!(StubBot)

    :ok
  end

  defp camera_arg(argv), do: argv |> Enum.drop_while(&(&1 != "--camera")) |> Enum.at(1)

  describe "discovery" do
    test "finds every camera on a running robot" do
      cameras = BB.Camera.discover(StubBot)

      assert cameras |> Enum.map(& &1.name) |> Enum.sort() == [:eye, :ghost, :right]
      assert Enum.all?(cameras, &(&1.module == Libcamera))

      eye = Enum.find(cameras, &(&1.name == :eye))
      assert eye.stream_info.format == :jpeg
      assert {eye.stream_info.width, eye.stream_info.height} == {640, 480}
    end

    test "reports no camera id or executable path through discovery" do
      text = StubBot |> BB.Camera.discover() |> inspect(limit: :infinity)

      refute String.contains?(text, "i2c@")
      refute String.contains?(text, "fake_rpicam_vid")
    end
  end

  describe "stream_info/1" do
    test "is pure, and answers for a robot that was never started" do
      assert {:ok, info} =
               Libcamera.stream_info(camera: "/no/such/camera", width: 320, height: 200)

      assert {info.width, info.height} == {320, 200}
      assert info.format == :jpeg
      assert info.metadata.pixel_format == nil
    end

    test "refuses to guess when an option is an unresolved parameter reference" do
      assert {:error, %UnknownStreamInfo{}} =
               Libcamera.stream_info(width: {:param, [:camera, :w]})
    end
  end

  describe "choosing a camera" do
    test "passes an index straight through" do
      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, _stub, {_executable, argv, _opts}}

      assert camera_arg(argv) == "0"

      Media.close(session)
    end

    test "resolves a libcamera id to the index rpicam-vid gives it" do
      {:ok, session} = Media.open(StubBot, :right, format: :jpeg)
      assert_receive {:stub_opened, _stub, {_executable, argv, _opts}}

      assert camera_arg(argv) == "1"
      refute Enum.any?(argv, &String.contains?(&1, "i2c@"))

      Media.close(session)
    end

    test "fails capture, naming the cameras it found, for an id that isn't there" do
      BB.subscribe(StubBot, [:sensor, :head, :ghost])

      {:ok, _session} = Media.open(StubBot, :ghost, format: :jpeg)

      assert_receive {:bb, _topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason == :error
      assert {:unknown_camera, _id, [_left, _right]} = ended.error.reason

      # Nothing was started against a camera that doesn't exist.
      refute_received {:stub_opened, _stub, _command}
    end

    test "two cameras capture independently" do
      {:ok, eye} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, eye_stub, {_executable, eye_argv, _opts}}
      assert camera_arg(eye_argv) == "0"

      {:ok, right} = Media.open(StubBot, :right, format: :jpeg)
      assert_receive {:stub_opened, right_stub, {_executable, right_argv, _opts}}
      assert camera_arg(right_argv) == "1"

      eye_image = JpegBuilder.build(width: 640, height: 480)
      right_image = JpegBuilder.build(width: 1280, height: 720)

      :ok = StubBackend.feed(right_stub, right_image)
      :ok = StubBackend.feed(eye_stub, eye_image)

      assert {:ok, %{data: ^eye_image}} = Media.next(eye, 5_000)
      assert {:ok, %{data: ^right_image}} = Media.next(right, 5_000)

      # Stopping one leaves the other running.
      :ok = Media.close(eye)
      assert_receive {:stub_stop_requested, ^eye_stub}
      :ok = StubBackend.exited(eye_stub, 0)

      next_image = JpegBuilder.build(width: 1280, height: 720, entropy: "second image")
      :ok = StubBackend.feed(right_stub, next_image)
      assert {:ok, %{data: ^next_image}} = Media.next(right, 5_000)

      Media.close(right)
    end
  end

  describe "one capture, many consumers" do
    test "two consumers share a single capture" do
      {:ok, first} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      {:ok, second} = Media.open(StubBot, :eye, format: :jpeg)

      # A second rpicam-vid would have announced itself here.
      refute_received {:stub_opened, _other, _command}

      image = JpegBuilder.build(width: 640, height: 480)
      :ok = StubBackend.feed(stub, image)

      assert {:ok, frame_one} = Media.next(first, 5_000)
      assert {:ok, frame_two} = Media.next(second, 5_000)
      assert frame_one.data == image
      assert frame_two.data == image

      Media.close(first)
      Media.close(second)
    end

    test "no second capture is opened until the first has really gone" do
      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}

      # The stub has been asked to stop but has not exited, so as far as this
      # driver knows rpicam-vid still holds the camera.
      {:ok, _session} = Media.open(StubBot, :eye, format: :jpeg)

      # A synchronous round trip through the hub proves the request has been
      # handled, so an empty mailbox means no second capture was opened.
      BB.Camera.stream_info(StubBot, :eye)
      refute_received {:stub_opened, _other, _command}

      # Once the old one is really gone, the new one starts.
      :ok = StubBackend.exited(stub, 0)
      assert_receive {:stub_opened, second, _command}
      refute second == stub
    end

    test "capture stops when the last consumer leaves, and starts again for the next" do
      {:ok, session} = Media.open(StubBot, :right, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 0)

      # The id is resolved again for the second capture, not remembered.
      {:ok, session} = Media.open(StubBot, :right, format: :jpeg)
      assert_receive {:stub_opened, _stub, {_executable, argv, _opts}}
      assert camera_arg(argv) == "1"

      Media.close(session)
    end
  end

  describe "lifecycle on pubsub" do
    test "publishes capture start and end, and never a frame" do
      BB.subscribe(StubBot, @topic)

      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      # Nothing has been captured yet, so nothing claims it has been.
      BB.Camera.stream_info(StubBot, :eye)
      refute_received {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}

      :ok = StubBackend.feed(stub, JpegBuilder.build())

      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{} = begun}}
      assert begun.stream_info.format == :jpeg

      assert {:ok, _frame} = Media.next(session, 5_000)

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason in [:no_subscribers, :driver_stopped]

      refute_received {:bb, @topic, %BB.Message{payload: %{data: _data}}}
    end

    test "a capture that never produces a frame is a failure, not a beginning" do
      BB.subscribe(StubBot, @topic)

      {:ok, _session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      # rpicam-vid exits 255 without writing an image when the camera is held
      # by another process or its buffers cannot be allocated.
      :ok = StubBackend.exited(stub, 255)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason == :error
      assert ended.error

      refute_received {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}
    end
  end

  describe "reporting what the camera actually produced" do
    test "corrects the declared dimensions from the frame's own header" do
      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      :ok = StubBackend.feed(stub, JpegBuilder.build(width: 320, height: 240))

      assert {:ok, frame} = Media.next(session, 5_000)
      assert {frame.width, frame.height} == {320, 240}

      assert {:ok, info} = BB.Camera.stream_info(StubBot, :eye)
      assert {info.width, info.height} == {320, 240}

      Media.close(session)
    end

    test "reports the chroma subsampling it read out of the frame" do
      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}

      :ok = StubBackend.feed(stub, JpegBuilder.build(sampling: {2, 1}))
      assert {:ok, _frame} = Media.next(session, 5_000)

      assert {:ok, info} = BB.Camera.stream_info(StubBot, :eye)
      assert info.metadata.pixel_format == :I422

      Media.close(session)
    end
  end

  describe "reconfiguring from a parameter" do
    test "a new width restarts capture with it" do
      BB.subscribe(StubBot, @topic)

      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, stub, _command}
      :ok = StubBackend.feed(stub, JpegBuilder.build())
      assert {:ok, _frame} = Media.next(session, 5_000)
      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}

      :ok = BB.Parameter.set(StubBot, [:camera, :width], 320)

      # The running capture has to be gone before a replacement is opened.
      assert_receive {:stub_stop_requested, ^stub}
      refute_received {:stub_opened, _other, _command}
      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{reason: :driver_stopped}}}
      assert_receive {:stub_opened, restarted, {_executable, argv, _opts}}
      assert ["--width", "320"] == Enum.drop_while(argv, &(&1 != "--width")) |> Enum.take(2)

      # And the replacement only claims to be capturing once it really is.
      :ok = StubBackend.feed(restarted, JpegBuilder.build(width: 320, height: 480))
      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}
    end

    test "a value only the driver refuses takes the camera down with it" do
      # `-1` satisfies the parameter's `type: :integer` and is stored, then
      # fails the driver's `:pos_integer`. `handle_options/2` has no way to
      # refuse and stay running, so the sensor stops. This asserts the trap
      # rather than endorsing it; see `BB.Camera.Libcamera.handle_options/2`.
      sensor = BB.Process.whereis(StubBot, :eye)
      monitor = Process.monitor(sensor)

      :ok = BB.Parameter.set(StubBot, [:camera, :width], -1)

      assert_receive {:DOWN, ^monitor, :process, ^sensor, _reason}
    end
  end

  describe "the rpicam-vid command" do
    test "is built from the declared options without a shell" do
      {:ok, session} = Media.open(StubBot, :eye, format: :jpeg)
      assert_receive {:stub_opened, _stub, {executable, argv, _opts}}

      assert String.ends_with?(executable, "fake_rpicam_vid")
      assert Enum.take(argv, -3) == ["--flush", "--output", "-"]
      assert Enum.all?(argv, &is_binary/1)

      Media.close(session)
    end
  end
end
