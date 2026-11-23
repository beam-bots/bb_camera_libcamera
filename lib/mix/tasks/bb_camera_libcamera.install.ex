# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbCameraLibcamera.Install do
    @shortdoc "Installs BB.Camera.Libcamera into a robot"
    @moduledoc """
    #{@shortdoc}

    Adds a `:config.:camera` param group holding the camera's geometry, and
    imports `bb_camera_libcamera` into your formatter.

    The camera itself belongs on a specific link — whichever one it is bolted
    to — and the installer cannot guess which, nor which connector it is
    plugged into, so it prints a snippet to paste into the topology.

    ## Example

    ```bash
    mix igniter.install bb_camera_libcamera
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Formatter

    @param_group :camera

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string],
        aliases: [r: :robot]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)

      igniter
      |> Formatter.import_dep(:bb_camera_libcamera)
      |> BB.Igniter.add_param_group(robot_module, [:config, @param_group], param_group_body())
      |> Igniter.add_notice(topology_snippet())
    end

    defp param_group_body do
      """
      param :width, type: :integer, default: 640, doc: "Width in pixels; a multiple of 128"

      param :height, type: :integer, default: 480, doc: "Height in pixels; even"
      """
    end

    defp topology_snippet do
      """
      bb_camera_libcamera: add a camera to whichever link it is mounted on. Example:

          link :head do
            sensor :eye, {BB.Camera.Libcamera,
              camera: 0,
              width: param([:config, :camera, :width]),
              height: param([:config, :camera, :height]),
              frame_rate: 30
            }
          end

      With more than one camera, name each by its libcamera id rather than an
      index. List them on the Pi with `rpicam-vid --list-cameras`, or from IEx:

          BB.Camera.Libcamera.Devices.list()
      """
    end
  end
else
  defmodule Mix.Tasks.BbCameraLibcamera.Install do
    @shortdoc "Installs BB.Camera.Libcamera into a robot"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The bb_camera_libcamera.install task requires igniter.

          mix igniter.install bb_camera_libcamera
      """)

      exit({:shutdown, 1})
    end
  end
end
