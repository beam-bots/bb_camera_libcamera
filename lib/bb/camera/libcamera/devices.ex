# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.Devices do
  @moduledoc """
  The cameras `rpicam-vid` can see.

  This asks `rpicam-vid --list-cameras` rather than libcamera directly,
  because `rpicam-vid` is what will open the camera: its `--camera` index is
  an index into exactly this list, so the list is the only thing that can turn
  a camera id into the index to pass.

  ## Ids, not indices

  A camera's id is libcamera's, and on a Raspberry Pi it is the device-tree
  path of the sensor - which is to say, of the connector it is plugged into:

      /base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10
      /base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10

  Two identical sensors on a Pi 5 differ in nothing else. An index, by
  contrast, is a position in a list, and a camera that fails to probe at boot
  moves every camera after it up by one. Prefer the id on any board with more
  than one camera.

  Listing opens no camera and works while other cameras are capturing. A
  camera that another process holds is still listed, but libcamera cannot read
  its modes, and reports them as `65535x65535`; they are not parsed here.
  """

  @type device :: %{
          index: non_neg_integer(),
          id: String.t(),
          model: String.t(),
          description: String.t()
        }

  @doc """
  Ask `rpicam-vid` for its cameras.

  ## Options

  - `:executable` — path to `rpicam-vid`. Defaults to whatever is on `$PATH`.
  """
  @spec list(keyword()) :: {:ok, [device()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, executable} <- executable(opts) do
      # The list goes to stdout and libcamera's logging to stderr, which is
      # left on the console rather than mixed in.
      case System.cmd(executable, ["--list-cameras"], env: [{"LIBCAMERA_LOG_LEVELS", "*:ERROR"}]) do
        {output, 0} -> {:ok, parse(output)}
        {output, status} -> {:error, {:list_failed, status, String.trim(output)}}
      end
    end
  end

  @doc """
  Find the index `rpicam-vid` currently gives the camera with `id`.
  """
  @spec index_of(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def index_of(id, opts \\ []) do
    with {:ok, devices} <- list(opts) do
      case Enum.find(devices, &(&1.id == id)) do
        nil -> {:error, {:unknown_camera, id, Enum.map(devices, & &1.id)}}
        device -> {:ok, device.index}
      end
    end
  end

  @doc """
  Read the cameras out of `rpicam-vid --list-cameras` output.

      iex> output = \"\"\"
      ...> Available cameras
      ...> -----------------
      ...> 0 : imx219 [3280x2464 10-bit RGGB] (/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10)
      ...>     Modes: 'SRGGB10_CSI2P' : 640x480 [103.33 fps - (1000, 752)/1280x960 crop]
      ...>                              1640x1232 [41.85 fps - (0, 0)/3280x2464 crop]
      ...>
      ...> 1 : imx708_wide [4608x2592 10-bit] (/base/axi/pcie@1000120000/rp1/i2c@80000/imx708@1a)
      ...>            'SBGGR8' : 640x480 [30.00 fps - (65535, 65535)/65535x65535 crop]
      ...> \"\"\"
      iex> BB.Camera.Libcamera.Devices.parse(output)
      [
        %{
          index: 0,
          id: "/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10",
          model: "imx219",
          description: "3280x2464 10-bit RGGB"
        },
        %{
          index: 1,
          id: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx708@1a",
          model: "imx708_wide",
          description: "4608x2592 10-bit"
        }
      ]

  Anything that is not a camera line - headings, modes, a message saying
  there are no cameras - is ignored.
  """
  @spec parse(String.t()) :: [device()]
  def parse(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(&device/1)
  end

  defp device(line) do
    case Regex.run(~r/^(\d+) : (\S+) \[([^\]]*)\] \((.+)\)\s*$/, line) do
      [_line, index, model, description, id] ->
        [%{index: String.to_integer(index), id: id, model: model, description: description}]

      nil ->
        []
    end
  end

  defp executable(opts) do
    case Keyword.get(opts, :executable) || System.find_executable("rpicam-vid") do
      nil -> {:error, {:rpicam_vid_not_found, "rpicam-vid"}}
      path -> {:ok, path}
    end
  end
end
