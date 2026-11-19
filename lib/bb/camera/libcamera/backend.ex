# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.Backend do
  @moduledoc """
  Runs `rpicam-vid` under MuonTrap, behind an Erlang port.

  Everything `BB.Camera.FFmpeg.Backend.MuonTrap` says about why MuonTrap is
  here holds for `rpicam-vid` too: it cannot outlive its owner or the VM, no
  pid is ever signalled from outside, and its output is flow-controlled. Only
  `open/3` differs, and acknowledging, stopping and closing are delegated to
  it unchanged.

  ## Why not `BB.Camera.FFmpeg.Backend.MuonTrap` itself

  That backend refuses any argument vector without `-nostdin`, because ffmpeg
  reads its stdin for keyboard commands and would steal MuonTrap's
  acknowledgements. `rpicam-vid` has no such flag - it would refuse it as
  unknown - and has no need of one: it reads stdin only when started with
  `--keypress`, which this driver never passes. Measured on a Pi 5 through a
  16 KiB `:stdio_window`, 170 KB of frames arrived, which is only possible if
  every acknowledgement reached MuonTrap.

  ## libcamera's logging

  libcamera logs at `INFO` to stderr by default: half a dozen lines on every
  capture start. `rpicam-vid --verbose 0` quietens `rpicam-vid` but not
  libcamera, so this sets `LIBCAMERA_LOG_LEVELS` to `:log_levels`, by default
  `"*:WARN"`. stderr itself is left attached to the VM's, as with ffmpeg: a
  busy camera or a failed buffer allocation is explained there, and nowhere
  else.
  """

  @behaviour BB.Camera.FFmpeg.Backend

  alias BB.Camera.FFmpeg.Backend.MuonTrap, as: MuonTrapBackend

  @default_log_levels "*:WARN"

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  def open(executable, args, opts) do
    {:ok,
     Port.open(
       {:spawn_executable, MuonTrap.muontrap_path()},
       port_options(executable, args, opts)
     )}
  rescue
    error -> {:error, error}
  end

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  defdelegate ack(port, bytes), to: MuonTrapBackend

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  defdelegate request_stop(port), to: MuonTrapBackend

  @doc false
  @impl BB.Camera.FFmpeg.Backend
  defdelegate close(port), to: MuonTrapBackend

  defp port_options(executable, args, opts) do
    muontrap_args =
      [
        "--capture-output",
        "--delay-to-sigkill",
        Integer.to_string(Keyword.fetch!(opts, :stop_timeout_ms)),
        "--stdio-window",
        Integer.to_string(Keyword.fetch!(opts, :stdio_window)),
        "--",
        executable
      ] ++ args

    log_levels = Keyword.get(opts, :log_levels, @default_log_levels)

    [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      args: muontrap_args,
      env: [{~c"LIBCAMERA_LOG_LEVELS", String.to_charlist(log_levels)}]
    ]
  end
end
