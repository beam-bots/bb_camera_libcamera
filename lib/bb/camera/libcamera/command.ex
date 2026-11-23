# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.Command do
  @moduledoc """
  The `rpicam-vid` invocation for one capture, built and validated up front.

  Keeping this separate from the process that runs it means the exact argument
  vector for a given set of camera options is a pure function, and can be
  asserted on without a camera, without `rpicam-vid`, and without starting
  anything.

  ## No shell, ever

  The vector is handed to MuonTrap, which `execvp`s `rpicam-vid` with the
  arguments as given. No shell parses them.

  ## Which camera

  `rpicam-vid --camera` takes an index into its own camera list, and that list
  is the only thing the index means anything against. A camera named by its
  libcamera id is therefore resolved to an index by asking the same executable
  for that list - see `BB.Camera.Libcamera.Devices` - immediately before each
  capture, rather than once and remembered. `argv/2` takes the resolved index;
  the command itself holds what was asked for.

  ## No encoding

  `--codec yuv420` selects `rpicam-vid`'s null encoder, which writes each of
  the ISP's YUV420 buffers to stdout as it is, one `fwrite` per frame. Nothing
  is encoded on the Pi's CPU. The buffer includes the ISP's row padding, which
  `rpicam-vid` neither strips nor reports, so the frames are only tightly
  packed `:I420` at widths that need none; `BB.Camera.Libcamera` refuses the
  rest.

  ## Nothing else on stdout

  The stream is cut into frames by size alone, so a single stray byte on
  stdout would misalign every frame after it. `rpicam-vid` logs to stderr,
  and writes to stdout only the frames given `--output -`, its `--help`,
  `--version` and `--list-cameras` output, and metadata when asked for
  `--metadata -`. None of those is ever passed here.
  """

  alias BB.Camera.FFmpeg.FrameRate

  defstruct [
    :camera,
    :width,
    :height,
    :frame_rate,
    :hflip,
    :vflip,
    :buffer_count,
    :executable
  ]

  @typedoc """
  Which camera to capture from: an index into `rpicam-vid --list-cameras`, or
  a libcamera camera id such as
  `"/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10"`.
  """
  @type camera :: {:index, non_neg_integer()} | {:id, String.t()}

  @type t :: %__MODULE__{
          camera: camera(),
          width: pos_integer(),
          height: pos_integer(),
          frame_rate: FrameRate.t(),
          hflip: boolean(),
          vflip: boolean(),
          buffer_count: pos_integer() | nil,
          executable: String.t()
        }

  @type error ::
          {:invalid_camera, term()}
          | {:invalid_dimension, term()}
          | {:invalid_frame_rate, term()}
          | {:invalid_flip, term()}
          | {:invalid_buffer_count, term()}
          | {:rpicam_vid_not_found, term()}

  @doc """
  Build and validate a command.

  ## Options

  - `:camera` — an index into `rpicam-vid --list-cameras`, or a libcamera
    camera id from the same list. Default `0`.
  - `:width`, `:height` — positive pixel dimensions. libcamera picks the
    sensor mode and the ISP scales to fit. Whether a frame of that size comes
    out tightly packed is `BB.Camera.Libcamera`'s concern, not this module's.
  - `:frame_rate` — see `BB.Camera.FFmpeg.FrameRate`.
  - `:hflip`, `:vflip` — mirror the image. Both together rotate it by 180°,
    for a camera mounted upside down. Default `false`.
  - `:buffer_count` — how many frame buffers libcamera allocates. Default
    `nil`, leaving it to `rpicam-vid`. Fewer buffers use less CMA, which is
    what lets several cameras capture at once on a board with little of it.
  - `:executable` — path to `rpicam-vid`. Defaults to whatever is on `$PATH`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(opts) do
    with {:ok, camera} <- validate_camera(Keyword.get(opts, :camera, 0)),
         {:ok, width} <- validate_dimension(Keyword.get(opts, :width)),
         {:ok, height} <- validate_dimension(Keyword.get(opts, :height)),
         {:ok, frame_rate} <- validate_frame_rate(Keyword.get(opts, :frame_rate)),
         {:ok, hflip} <- validate_flip(Keyword.get(opts, :hflip, false)),
         {:ok, vflip} <- validate_flip(Keyword.get(opts, :vflip, false)),
         {:ok, buffer_count} <- validate_buffer_count(Keyword.get(opts, :buffer_count)),
         {:ok, executable} <- validate_executable(Keyword.get(opts, :executable)) do
      {:ok,
       %__MODULE__{
         camera: camera,
         width: width,
         height: height,
         frame_rate: frame_rate,
         hflip: hflip,
         vflip: vflip,
         buffer_count: buffer_count,
         executable: executable
       }}
    end
  end

  @doc """
  The argument vector for capturing from the camera at `index`, without the
  executable itself.

      iex> {:ok, command} = BB.Camera.Libcamera.Command.new(
      ...>   width: 640, height: 480, frame_rate: 30, executable: "/usr/bin/rpicam-vid")
      iex> BB.Camera.Libcamera.Command.argv(command, 0)
      ["--nopreview", "--timeout", "0", "--verbose", "0", "--camera", "0", "--codec",
       "yuv420", "--width", "640", "--height", "480", "--framerate", "30.0", "--flush",
       "--output", "-"]

      iex> {:ok, command} = BB.Camera.Libcamera.Command.new(
      ...>   camera: 1, width: 1280, height: 720, frame_rate: {30_000, 1001}, hflip: true,
      ...>   vflip: true, buffer_count: 2, executable: "/usr/bin/rpicam-vid")
      iex> BB.Camera.Libcamera.Command.argv(command, 1)
      ["--nopreview", "--timeout", "0", "--verbose", "0", "--camera", "1", "--codec",
       "yuv420", "--width", "1280", "--height", "720", "--framerate", "29.97002997002997",
       "--hflip", "--vflip", "--buffer-count", "2", "--flush", "--output", "-"]
  """
  @spec argv(t(), non_neg_integer()) :: [String.t()]
  def argv(%__MODULE__{} = command, index) when is_integer(index) and index >= 0 do
    # `--flush` writes each frame to the pipe as soon as it is captured. Without
    # it, frames sit in stdio's buffer and arrive in lumps.
    [
      "--nopreview",
      "--timeout",
      "0",
      "--verbose",
      "0",
      "--camera",
      Integer.to_string(index),
      "--codec",
      "yuv420",
      "--width",
      Integer.to_string(command.width),
      "--height",
      Integer.to_string(command.height),
      "--framerate",
      command.frame_rate |> FrameRate.to_float() |> Float.to_string()
    ] ++
      flag(command.hflip, "--hflip") ++
      flag(command.vflip, "--vflip") ++
      buffer_count_argv(command.buffer_count) ++
      ["--flush", "--output", "-"]
  end

  defp flag(true, name), do: [name]
  defp flag(false, _name), do: []

  defp buffer_count_argv(nil), do: []
  defp buffer_count_argv(count), do: ["--buffer-count", Integer.to_string(count)]

  defp validate_camera(index) when is_integer(index) and index >= 0, do: {:ok, {:index, index}}

  defp validate_camera(id) when is_binary(id) do
    cond do
      id == "" -> {:error, {:invalid_camera, id}}
      String.contains?(id, <<0>>) -> {:error, {:invalid_camera, id}}
      true -> {:ok, {:id, id}}
    end
  end

  defp validate_camera(camera), do: {:error, {:invalid_camera, camera}}

  defp validate_dimension(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_dimension(value), do: {:error, {:invalid_dimension, value}}

  defp validate_frame_rate(value) do
    case FrameRate.new(value) do
      {:ok, frame_rate} -> {:ok, frame_rate}
      {:error, _reason} -> {:error, {:invalid_frame_rate, value}}
    end
  end

  defp validate_flip(value) when is_boolean(value), do: {:ok, value}
  defp validate_flip(value), do: {:error, {:invalid_flip, value}}

  defp validate_buffer_count(nil), do: {:ok, nil}
  defp validate_buffer_count(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_buffer_count(value), do: {:error, {:invalid_buffer_count, value}}

  defp validate_executable(nil) do
    case System.find_executable("rpicam-vid") do
      nil -> {:error, {:rpicam_vid_not_found, "rpicam-vid"}}
      path -> {:ok, path}
    end
  end

  defp validate_executable(path) when is_binary(path), do: {:ok, path}
  defp validate_executable(path), do: {:error, {:rpicam_vid_not_found, path}}
end
