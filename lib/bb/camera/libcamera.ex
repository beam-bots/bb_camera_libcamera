# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera do
  @moduledoc """
  A Raspberry Pi camera, captured from libcamera through `rpicam-vid`.

  Declared like any other sensor:

      topology do
        link :head do
          sensor :eye, {BB.Camera.Libcamera, camera: 0, width: 1280, height: 720}
        end
      end

  Consumers never talk to this module. They go through `BB.Camera`, which
  refcounts them and asks the driver to start capturing when the first one
  arrives and to stop when the last one leaves. Two browser tabs on the same
  camera produce one `rpicam-vid`, not two.

  ## More than one camera

  A Pi 5 has two camera connectors, and a Compute Module carrier may have
  more. Declare one sensor per camera, each naming its own:

      link :head do
        sensor :left_eye, {BB.Camera.Libcamera,
          camera: "/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10"}
        sensor :right_eye, {BB.Camera.Libcamera,
          camera: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10"}
      end

  `:camera` is an index or a libcamera camera id, both as
  `BB.Camera.Libcamera.Devices.list/1` reports them. Prefer the id when there
  is more than one camera: it names the connector, while an index is a
  position in a list that shifts when a camera fails to probe. An id is
  resolved to an index by listing the cameras afresh at the start of each
  capture, which takes about a tenth of a second.

  Each camera is captured by its own `rpicam-vid`, and each allocates its frame
  buffers from the kernel's contiguous memory (CMA). A board with little of it
  - 64 MiB is common - can run out with two cameras at 720p, and the second
  capture then fails with `dmaHeap allocation failure` on the console. Either
  give the kernel more CMA, or lower `:buffer_count`; see `options_schema/0`.

  ## What it captures

  JPEG, encoded in software by `rpicam-vid`. A Pi camera produces raw Bayer
  data, the Pi's ISP turns it into YUV, and `rpicam-vid` encodes that with
  libjpeg, so every frame costs CPU in proportion to its size. `:quality`
  trades size for fidelity.

  ## What it reports

  Capture is confirmed to the hub on the **first whole image**, not when
  `rpicam-vid` starts. A camera that is missing, busy, or cannot get buffers
  would otherwise announce `BeginCapture` a moment before failing.

  Dimensions come from the `SOF` marker of each frame, which is what was
  actually encoded, and `BB.Camera.stream_info/2` reports those once capture
  has produced something.

  The frame rate in `stream_info` is the one that was **requested**. libcamera
  is asked for it, and chooses a sensor mode that can deliver it, but this
  driver does not read back what it got. What the frames actually did is
  measured by `BB.Camera.Hub` and reported separately in
  `BB.Message.Camera.CaptureState`.

  ## Frames do not go on pubsub

  A robot's pubsub carries capture lifecycle only:
  `BB.Message.Camera.BeginCapture` and `EndCapture`, published by the hub.
  Frame bytes travel over `BB.Camera`'s bounded media interface, and never
  appear in an event or an error.

  ## Options

  See `options_schema/0`. Any of them can be filled from a parameter with
  `param/1`, and changing that parameter while the robot runs reconfigures the
  camera - see `handle_options/2`.

  ## Limitations

  - **Raspberry Pi only**, in practice: `rpicam-vid` is built for the Pi's
    camera stack.
  - **Timestamps are arrival times.** The MJPEG stream on `rpicam-vid`'s
    stdout carries no timestamps, so a frame is stamped when the read
    completing it reached the BEAM. See `BB.Camera.FFmpeg.Capture` for what
    that does and does not mean.
  - **A failed capture is not retried.** The failure is reported and capture
    ends; reopening the camera is the consumer's decision, taken by
    subscribing again.
  - **Changing an option that reaches `rpicam-vid` restarts it.** Capture ends
    and begins again around the change, with the events to match.
  - **`rpicam-vid`'s diagnostics go to the VM's console**, not into the error.
  """

  use BB.Sensor
  use BB.Camera

  import BB.Unit
  import BB.Unit.Option

  alias BB.Camera.FFmpeg.{Capture, FrameRate}
  alias BB.Camera.{Frame, Hub, StreamInfo}
  alias BB.Camera.Libcamera.{Command, Devices}
  alias BB.Error.Hardware.Camera.CaptureFailed

  require Logger

  @impl BB.Sensor
  def options_schema do
    Spark.Options.new!(
      camera: [
        type: {:or, [:non_neg_integer, :string]},
        default: 0,
        doc: """
        Which camera: its index in `rpicam-vid --list-cameras`, or its
        libcamera id from the same list. Prefer the id on a board with more
        than one camera. See `BB.Camera.Libcamera.Devices`
        """
      ],
      width: [
        type: :pos_integer,
        default: 640,
        doc: "Width in pixels to ask for"
      ],
      height: [
        type: :pos_integer,
        default: 480,
        doc: "Height in pixels to ask for"
      ],
      frame_rate: [
        type: FrameRate.option_type(),
        default: 30,
        doc: "Frames per second to ask for; see `BB.Camera.FFmpeg.FrameRate`"
      ],
      quality: [
        type: {:in, 1..100},
        default: 50,
        doc: "JPEG quality, 1 to 100. `rpicam-vid`'s own default is 50"
      ],
      hflip: [
        type: :boolean,
        default: false,
        doc: "Mirror the image horizontally"
      ],
      vflip: [
        type: :boolean,
        default: false,
        doc: "Mirror the image vertically. With `:hflip`, a camera mounted upside down"
      ],
      buffer_count: [
        type: {:or, [:pos_integer, nil]},
        default: nil,
        doc: """
        Frame buffers for libcamera to allocate, or `nil` for `rpicam-vid`'s
        default. Fewer buffers use less CMA; `2` lets two 720p cameras run on a
        Pi 5 with 64 MiB of it, at some risk of dropped frames under load
        """
      ],
      rpicam_vid: [
        type: :string,
        required: false,
        doc: "Path to the `rpicam-vid` executable. Defaults to the one on $PATH"
      ],
      publish_rate: [
        type: unit_type(compatible: :hertz),
        default: ~u(1 hertz),
        doc: "How often the hub publishes `BB.Message.Camera.CaptureState`"
      ],
      max_frame_bytes: [
        type: :pos_integer,
        default: 4 * 1024 * 1024,
        doc: "Largest frame to accept. See `BB.Camera.FFmpeg.Framer`"
      ],
      drop_queue_len: [
        type: :pos_integer,
        default: 8,
        doc: "Shed frames while more reads than this are waiting"
      ],
      stdio_window: [
        type: :pos_integer,
        default: 256 * 1024,
        doc: "Bytes of output `rpicam-vid` may have in flight before they are acknowledged"
      ],
      start_timeout_ms: [
        type: :pos_integer,
        default: 10_000,
        doc: "How long to wait for the first frame before failing capture"
      ],
      stop_timeout_ms: [
        type: :non_neg_integer,
        default: 2_000,
        doc: "How long `rpicam-vid` gets to exit on `SIGTERM` before it is sent `SIGKILL`"
      ],
      backend: [
        type: {:behaviour, BB.Camera.FFmpeg.Backend},
        default: BB.Camera.Libcamera.Backend,
        doc: """
        What produces the bytes. The default runs `rpicam-vid` under MuonTrap;
        tests declare `BB.Camera.FFmpeg.Test.StubBackend` here to drive capture
        read by read without a camera.
        """
      ],
      backend_opts: [
        type: :keyword_list,
        default: [],
        doc: "Passed to the backend's `open/3`. See `BB.Camera.Libcamera.Backend`"
      ]
    )
  end

  @doc """
  The format this camera is declared to produce.

  Pure: it is called during discovery against robots that are not running, so
  it reads the options and nothing else. Options that still hold unresolved
  parameter references cannot imply a format, and produce an error rather than
  a guess.
  """
  @impl BB.Camera
  def stream_info(opts) do
    with {:ok, width} <- fetch_dimension(opts, :width),
         {:ok, height} <- fetch_dimension(opts, :height),
         {:ok, frame_rate} <- fetch_frame_rate(opts) do
      StreamInfo.new(
        format: :jpeg,
        width: width,
        height: height,
        frame_rate: frame_rate,
        metadata: %{pixel_format: nil}
      )
    end
  end

  @impl BB.Sensor
  def init(opts) do
    # A camera that cannot be opened is an ordinary condition - an unplugged
    # ribbon, a camera another process holds, buffers that cannot be
    # allocated - and the hub has an event for saying so. Letting the linked
    # capture's exit kill the sensor instead would replace that diagnosis with
    # a crash, and a restart loop against hardware that is simply absent.
    Process.flag(:trap_exit, true)

    with {:ok, stream_info} <- stream_info(opts),
         {:ok, command} <- build_command(opts) do
      {:ok, hub} =
        Hub.start_link(
          bb: opts[:bb],
          stream_info: stream_info,
          publish_rate: opts[:publish_rate]
        )

      {:ok,
       %{
         bb: opts[:bb],
         capture: nil,
         command: command,
         dimensions: nil,
         hub: hub,
         opts: opts,
         pending: nil,
         sequence: 0,
         stopping: nil,
         stream_info: stream_info
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl BB.Sensor
  def handle_info({:bb_camera, :start_capture}, state), do: {:noreply, request_start(state)}

  def handle_info({:bb_camera, :stop_capture}, state),
    do: {:noreply, request_stop(state, :driver_stopped)}

  def handle_info({:bb_camera_ffmpeg, capture, {:ready, info}}, %{capture: capture} = state),
    do: {:noreply, confirm(state, info)}

  def handle_info({:bb_camera_ffmpeg, capture, event}, %{capture: capture} = state),
    do: {:noreply, handle_capture_event(state, event)}

  def handle_info({:EXIT, capture, reason}, %{stopping: capture} = state) do
    state = %{state | stopping: nil}

    if teardown_confirmed?(reason) do
      {:noreply, run_pending(state)}
    else
      {:noreply, abandon_pending(state, reason)}
    end
  end

  def handle_info({:EXIT, capture, reason}, %{capture: capture} = state) do
    Logger.warning("capture for #{inspect(camera_name(state))} ended: #{inspect(reason)}")

    Hub.capture_failed(state.hub, %CaptureFailed{camera: camera_name(state), reason: reason})

    {:noreply, run_pending(%{state | capture: nil, dimensions: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Take up options that changed while the robot was running.

  Reached when a `param/1` reference in the camera's DSL options resolves to a
  new value. Only a change that alters the `rpicam-vid` invocation restarts
  capture: libcamera configures the camera once, when it starts, so a new size
  or rate means a new `rpicam-vid`. Capture stops and starts again around the
  change; it is not a seamless transition and does not pretend to be. An
  option that doesn't reach the command line - a framer bound, say - takes
  effect without disturbing the stream.

  **New options this driver cannot use stop the camera.** `handle_options/2`
  has no way to refuse a change and stay running, so a value that satisfies
  the parameter's declared type but not this driver - a width of `-1` against
  a `:pos_integer` - takes the sensor down, and down again on each restart,
  because the parameter was stored before anyone was asked about it. Declare
  parameters with bounds that match the options they feed.
  """
  @impl BB.Sensor
  def handle_options(opts, state) do
    with {:ok, stream_info} <- stream_info(opts),
         {:ok, command} <- build_command(opts) do
      state = %{state | opts: opts, stream_info: stream_info}

      if command == state.command do
        {:ok, state}
      else
        {:ok, restart_for(%{state | command: command})}
      end
    end
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl BB.Sensor
  def terminate(_reason, state) do
    if state.capture, do: Capture.stop(state.capture)

    :ok
  end

  # ----------------------------------------------------------------------------
  # Lifecycle
  #
  # Only one process may hold a camera at a time, which makes "stop" and
  # "start again" a sequence rather than two independent events. A capture that
  # has been asked to stop keeps its identity in `:stopping` until its real
  # exit arrives, and whatever wanted to happen next waits in `:pending`. The
  # alternative - forgetting the old capture and opening a new one immediately -
  # produces two `rpicam-vid`s contending for one camera, and libcamera refuses
  # the second in a way that looks like broken hardware.
  # ----------------------------------------------------------------------------

  defp request_start(%{capture: capture} = state) when is_pid(capture), do: state

  defp request_start(%{stopping: stopping} = state) when is_pid(stopping),
    do: queue(state, :start)

  defp request_start(state), do: start_capture(state)

  defp request_stop(%{capture: capture} = state, reason) when is_pid(capture),
    do: begin_stop(state, {:stop, reason})

  defp request_stop(%{stopping: stopping} = state, reason) when is_pid(stopping),
    do: queue(state, {:stop, reason})

  defp request_stop(state, reason) do
    Hub.capture_stopped(state.hub, reason)

    state
  end

  # A camera that isn't capturing has nothing to restart: the new command is
  # already in state, and whenever the hub next asks for capture it is used.
  defp restart_for(%{capture: capture} = state) when is_pid(capture),
    do: begin_stop(state, :reconfigure)

  defp restart_for(%{stopping: stopping} = state) when is_pid(stopping),
    do: queue(state, :reconfigure)

  defp restart_for(state), do: state

  defp begin_stop(state, pending) do
    capture = state.capture
    state = %{state | sequence: next_sequence(state)}

    Capture.stop(capture)

    %{state | capture: nil, dimensions: nil, stopping: capture, pending: pending}
  end

  defp queue(state, pending), do: %{state | pending: pending}

  defp run_pending(%{pending: nil} = state), do: state

  defp run_pending(%{pending: {:stop, reason}} = state) do
    Hub.capture_stopped(state.hub, reason)

    %{state | pending: nil}
  end

  defp run_pending(%{pending: :start} = state), do: start_capture(%{state | pending: nil})

  defp run_pending(%{pending: :reconfigure} = state) do
    # The docs promise an end and a beginning around an option change, because
    # that is what actually happens: libcamera configures the camera on start,
    # so a new size or rate means a new `rpicam-vid`.
    Hub.capture_stopped(state.hub, :driver_stopped)

    start_capture(%{state | pending: nil})
  end

  # A capture whose teardown could not be confirmed may still be holding the
  # camera. Opening a second one would contend with it, so whatever was waiting
  # is abandoned and said so, rather than attempted and blamed on the camera.
  defp abandon_pending(state, reason) do
    Logger.error(
      "capture for #{inspect(camera_name(state))} did not confirm teardown: #{inspect(reason)}"
    )

    error = %CaptureFailed{camera: camera_name(state), reason: reason}

    case state.pending do
      {:stop, stop_reason} -> Hub.capture_stopped(state.hub, stop_reason)
      pending when pending in [:start, :reconfigure] -> Hub.capture_failed(state.hub, error)
      nil -> :ok
    end

    %{state | pending: nil}
  end

  defp teardown_confirmed?({:shutdown, :teardown_unconfirmed}), do: false
  defp teardown_confirmed?(_reason), do: true

  defp start_capture(state) do
    with {:ok, index} <- resolve_camera(state.command),
         {:ok, capture, dimensions} <- start_capture(state, index) do
      %{state | capture: capture, dimensions: dimensions}
    else
      {:error, reason} ->
        Hub.capture_failed(state.hub, %CaptureFailed{camera: camera_name(state), reason: reason})

        state
    end
  end

  defp start_capture(state, index) do
    hub = state.hub

    # The dimensions the hub has been told about, shared between this process
    # and the capture process that writes them.
    dimensions = :atomics.new(2, signed: false)

    opts =
      [
        args: Command.argv(state.command, index),
        executable: state.command.executable,
        notify: self(),
        sequence_start: state.sequence,
        sink: fn frame -> deliver(hub, state.stream_info, dimensions, frame) end
      ] ++ Keyword.take(state.opts, capture_option_keys())

    with {:ok, capture} <- Capture.start_link(opts), do: {:ok, capture, dimensions}
  end

  defp resolve_camera(%Command{camera: {:index, index}}), do: {:ok, index}

  defp resolve_camera(%Command{camera: {:id, id}} = command),
    do: Devices.index_of(id, executable: command.executable)

  # Capture is confirmed on the first whole image, not when `rpicam-vid`
  # starts. The process existing says nothing about whether the camera opened,
  # and a missing camera would otherwise announce `BeginCapture` a moment
  # before it failed.
  defp confirm(state, info) do
    stream_info = %{
      state.stream_info
      | width: info.width,
        height: info.height,
        metadata: Map.put(state.stream_info.metadata, :pixel_format, info.chroma_format)
    }

    :atomics.put(state.dimensions, 1, info.width)
    :atomics.put(state.dimensions, 2, info.height)

    Hub.capture_started(state.hub, stream_info)
    Capture.go(state.capture)

    %{state | stream_info: stream_info}
  end

  defp deliver(hub, declared, dimensions, frame) do
    known = {:atomics.get(dimensions, 1), :atomics.get(dimensions, 2)}

    if {frame.width, frame.height} != known do
      Hub.update_stream_info(hub, %{declared | width: frame.width, height: frame.height})
      :atomics.put(dimensions, 1, frame.width)
      :atomics.put(dimensions, 2, frame.height)
    end

    Hub.deliver(
      hub,
      Frame.new!(
        format: :jpeg,
        width: frame.width,
        height: frame.height,
        data: frame.data,
        sequence: frame.sequence,
        monotonic_time: frame.monotonic_time,
        wall_time: frame.wall_time,
        metadata: frame.metadata
      )
    )
  end

  defp handle_capture_event(state, {:exited, status}) do
    Logger.info("rpicam-vid for #{inspect(camera_name(state))} exited with status #{status}")

    state
  end

  defp handle_capture_event(state, {:discarded, bytes, reason}) do
    Logger.warning(
      "#{inspect(camera_name(state))} discarded #{bytes} bytes of capture: #{reason}"
    )

    state
  end

  defp handle_capture_event(state, {:dropped, count}) do
    Logger.debug("#{inspect(camera_name(state))} shed #{count} frames to keep up")

    state
  end

  defp handle_capture_event(state, {:no_frames, timeout_ms}) do
    Logger.warning(
      "#{inspect(camera_name(state))} produced no frame within #{timeout_ms}ms; " <>
        "rpicam-vid's console output above says why, if it knows"
    )

    state
  end

  defp handle_capture_event(state, {:sink_error, reason}) do
    Logger.warning("#{inspect(camera_name(state))} could not deliver a frame: #{inspect(reason)}")

    state
  end

  defp handle_capture_event(state, _event), do: state

  # Sequence numbers have to keep climbing across a restart: the hub rejects a
  # frame whose sequence does not strictly increase, and a capture that reset
  # its counter would have every frame refused as stale.
  defp next_sequence(%{capture: nil} = state), do: state.sequence

  defp next_sequence(state) do
    case Capture.stats(state.capture) do
      %{frames: frames} -> state.sequence + frames
      _other -> state.sequence
    end
  catch
    :exit, _reason -> state.sequence
  end

  defp build_command(opts) do
    command_opts =
      opts
      |> Keyword.take([
        :camera,
        :width,
        :height,
        :frame_rate,
        :quality,
        :hflip,
        :vflip,
        :buffer_count
      ])
      |> Keyword.put(:executable, opts[:rpicam_vid])

    case Command.new(command_opts) do
      {:ok, command} -> {:ok, command}
      {:error, reason} -> {:error, %CaptureFailed{camera: opts[:bb][:path], reason: reason}}
    end
  end

  defp capture_option_keys,
    do: [
      :backend,
      :backend_opts,
      :drop_queue_len,
      :max_frame_bytes,
      :start_timeout_ms,
      :stdio_window,
      :stop_timeout_ms
    ]

  defp camera_name(state), do: List.last(state.bb.path)

  defp fetch_dimension(opts, key) do
    case Keyword.get(opts, key, default_for(key)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> unknown_stream_info({key, other})
    end
  end

  defp fetch_frame_rate(opts) do
    case FrameRate.new(Keyword.get(opts, :frame_rate, 30)) do
      {:ok, rate} -> {:ok, FrameRate.to_float(rate)}
      {:error, reason} -> unknown_stream_info({:frame_rate, reason})
    end
  end

  defp default_for(:width), do: 640
  defp default_for(:height), do: 480

  defp unknown_stream_info(reason) do
    {:error, %BB.Error.Invalid.Camera.UnknownStreamInfo{module: __MODULE__, reason: reason}}
  end
end
