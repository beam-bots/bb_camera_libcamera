# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.LibcameraTest do
  @moduledoc false
  # The stub reports to a registered name, which is global.
  use ExUnit.Case, async: false

  alias BB.Camera.FFmpeg.Test.StubBackend
  alias BB.Camera.Libcamera
  alias BB.Camera.Libcamera.Test.StubBot
  alias BB.Camera.Media
  alias BB.Error.Invalid.Camera.{UnknownStreamInfo, UnsupportedFormat}
  alias BB.Message.Camera.{BeginCapture, EndCapture}

  @topic [:sensor, :head, :eye]

  setup do
    Process.register(self(), :bb_camera_libcamera_stub_observer)
    start_supervised!(StubBot)

    :ok
  end

  defp camera_arg(argv), do: argv |> Enum.drop_while(&(&1 != "--camera")) |> Enum.at(1)

  # One `:I420` frame filled with `label`, so a test can tell frames apart.
  defp frame(width, height, label \\ 0) do
    :binary.copy(<<label>>, div(width * height * 3, 2))
  end

  describe "discovery" do
    test "finds every camera on a running robot" do
      cameras = BB.Camera.discover(StubBot)

      assert cameras |> Enum.map(& &1.name) |> Enum.sort() == [:eye, :ghost, :right]
      assert Enum.all?(cameras, &(&1.module == Libcamera))

      eye = Enum.find(cameras, &(&1.name == :eye))
      assert eye.stream_info.format == {:raw, :I420}
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
               Libcamera.stream_info(camera: "/no/such/camera", width: 1920, height: 1080)

      assert {info.width, info.height} == {1920, 1080}
      assert info.format == {:raw, :I420}
    end

    test "refuses a width rpicam-vid would pad" do
      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions} = error} =
               Libcamera.stream_info(width: 800, height: 600)

      assert {error.format, error.width, error.height} == {{:raw, :I420}, 800, 600}
    end

    test "refuses an odd height" do
      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions}} =
               Libcamera.stream_info(width: 640, height: 481)
    end

    test "refuses to guess when an option is an unresolved parameter reference" do
      assert {:error, %UnknownStreamInfo{}} =
               Libcamera.stream_info(width: {:param, [:camera, :w]})
    end
  end

  describe "choosing a camera" do
    test "passes an index straight through" do
      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, _stub, {_executable, argv, _opts}}

      assert camera_arg(argv) == "0"

      Media.close(session)
    end

    test "resolves a libcamera id to the index rpicam-vid gives it" do
      {:ok, session} = Media.open(StubBot, :right, format: {:raw, :I420})
      assert_receive {:stub_opened, _stub, {_executable, argv, _opts}}

      assert camera_arg(argv) == "1"
      refute Enum.any?(argv, &String.contains?(&1, "i2c@"))

      Media.close(session)
    end

    test "fails capture, naming the cameras it found, for an id that isn't there" do
      BB.subscribe(StubBot, [:sensor, :head, :ghost])

      {:ok, _session} = Media.open(StubBot, :ghost, format: {:raw, :I420})

      assert_receive {:bb, _topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason == :error
      assert {:unknown_camera, _id, [_left, _right]} = ended.error.reason

      # Nothing was started against a camera that doesn't exist.
      refute_received {:stub_opened, _stub, _command}
    end

    test "two cameras capture independently" do
      {:ok, eye} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, eye_stub, {_executable, eye_argv, _opts}}
      assert camera_arg(eye_argv) == "0"

      {:ok, right} = Media.open(StubBot, :right, format: {:raw, :I420})
      assert_receive {:stub_opened, right_stub, {_executable, right_argv, _opts}}
      assert camera_arg(right_argv) == "1"

      eye_image = frame(640, 480, 1)
      right_image = frame(1280, 720, 2)

      :ok = StubBackend.feed(right_stub, right_image)
      :ok = StubBackend.feed(eye_stub, eye_image)

      assert {:ok, %{data: ^eye_image}} = Media.next(eye, 5_000)
      assert {:ok, %{data: ^right_image}} = Media.next(right, 5_000)

      # Stopping one leaves the other running.
      :ok = Media.close(eye)
      assert_receive {:stub_stop_requested, ^eye_stub}
      :ok = StubBackend.exited(eye_stub, 0)

      next_image = frame(1280, 720, 3)
      :ok = StubBackend.feed(right_stub, next_image)
      assert {:ok, %{data: ^next_image}} = Media.next(right, 5_000)

      Media.close(right)
    end
  end

  describe "one capture, many consumers" do
    test "two consumers share a single capture" do
      {:ok, first} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      {:ok, second} = Media.open(StubBot, :eye, format: {:raw, :I420})

      # A second rpicam-vid would have announced itself here.
      refute_received {:stub_opened, _other, _command}

      image = frame(640, 480)
      :ok = StubBackend.feed(stub, image)

      assert {:ok, frame_one} = Media.next(first, 5_000)
      assert {:ok, frame_two} = Media.next(second, 5_000)
      assert frame_one.data == image
      assert frame_two.data == image

      Media.close(first)
      Media.close(second)
    end

    test "no second capture is opened until the first has really gone" do
      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}

      # The stub has been asked to stop but has not exited, so as far as this
      # driver knows rpicam-vid still holds the camera.
      {:ok, _session} = Media.open(StubBot, :eye, format: {:raw, :I420})

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
      {:ok, session} = Media.open(StubBot, :right, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      :ok = Media.close(session)
      assert_receive {:stub_stop_requested, ^stub}
      :ok = StubBackend.exited(stub, 0)

      # The id is resolved again for the second capture, not remembered.
      {:ok, session} = Media.open(StubBot, :right, format: {:raw, :I420})
      assert_receive {:stub_opened, _stub, {_executable, argv, _opts}}
      assert camera_arg(argv) == "1"

      Media.close(session)
    end
  end

  describe "lifecycle on pubsub" do
    test "publishes capture start and end, and never a frame" do
      BB.subscribe(StubBot, @topic)

      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      # Nothing has been captured yet, so nothing claims it has been.
      BB.Camera.stream_info(StubBot, :eye)
      refute_received {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}

      :ok = StubBackend.feed(stub, frame(640, 480))

      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{} = begun}}
      assert begun.stream_info.format == {:raw, :I420}

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

      {:ok, _session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      # rpicam-vid exits 255 without writing a frame when the camera is held
      # by another process or its buffers cannot be allocated.
      :ok = StubBackend.exited(stub, 255)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{} = ended}}
      assert ended.reason == :error
      assert ended.error

      refute_received {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}
    end
  end

  describe "frames" do
    test "are raw I420 at the configured size, cut from the stream by size alone" do
      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      # One frame split across reads, as a pipe delivers it, and then the
      # start of the next: only the whole one is delivered.
      first = frame(640, 480, 1)
      <<head::binary-size(1000), tail::binary>> = first
      :ok = StubBackend.feed_all(stub, [head, tail <> binary_part(frame(640, 480, 2), 0, 10)])

      assert {:ok, delivered} = Media.next(session, 5_000)
      assert delivered.data == first
      assert {delivered.format, delivered.width, delivered.height} == {{:raw, :I420}, 640, 480}

      Media.close(session)
    end

    test "leave the declared stream info as it was" do
      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}

      :ok = StubBackend.feed(stub, frame(640, 480))
      assert {:ok, _frame} = Media.next(session, 5_000)

      assert {:ok, info} = BB.Camera.stream_info(StubBot, :eye)
      assert {info.format, info.width, info.height} == {{:raw, :I420}, 640, 480}

      Media.close(session)
    end
  end

  describe "reconfiguring from a parameter" do
    test "a new width restarts capture with it" do
      BB.subscribe(StubBot, @topic)

      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, stub, _command}
      :ok = StubBackend.feed(stub, frame(640, 480))
      assert {:ok, _frame} = Media.next(session, 5_000)
      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{}}}

      :ok = BB.Parameter.set(StubBot, [:camera, :width], 1280)

      # The running capture has to be gone before a replacement is opened.
      assert_receive {:stub_stop_requested, ^stub}
      refute_received {:stub_opened, _other, _command}
      :ok = StubBackend.exited(stub, 0)

      assert_receive {:bb, @topic, %BB.Message{payload: %EndCapture{reason: :driver_stopped}}}
      assert_receive {:stub_opened, restarted, {_executable, argv, _opts}}
      assert ["--width", "1280"] == Enum.drop_while(argv, &(&1 != "--width")) |> Enum.take(2)

      # And the replacement only claims to be capturing once it really is.
      :ok = StubBackend.feed(restarted, frame(1280, 480, 4))
      assert_receive {:bb, @topic, %BB.Message{payload: %BeginCapture{} = begun}}
      assert {begun.stream_info.width, begun.stream_info.height} == {1280, 480}

      # The old session ended with the old capture. A new one is handed the
      # frame that confirmed it, cut at the new size.
      assert {:error, _end_of_capture} = Media.next(session, 5_000)
      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})

      assert {:ok, delivered} = Media.next(session, 5_000)
      assert delivered.data == frame(1280, 480, 4)
      assert {delivered.width, delivered.height} == {1280, 480}

      Media.close(session)
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

    test "so does a width rpicam-vid would pad" do
      sensor = BB.Process.whereis(StubBot, :eye)
      monitor = Process.monitor(sensor)

      :ok = BB.Parameter.set(StubBot, [:camera, :width], 800)

      assert_receive {:DOWN, ^monitor, :process, ^sensor,
                      %UnsupportedFormat{reason: :invalid_dimensions}}
    end
  end

  describe "the rpicam-vid command" do
    test "is built from the declared options without a shell" do
      {:ok, session} = Media.open(StubBot, :eye, format: {:raw, :I420})
      assert_receive {:stub_opened, _stub, {executable, argv, _opts}}

      assert String.ends_with?(executable, "fake_rpicam_vid")
      assert Enum.take(argv, -3) == ["--flush", "--output", "-"]
      assert Enum.all?(argv, &is_binary/1)

      Media.close(session)
    end
  end
end
