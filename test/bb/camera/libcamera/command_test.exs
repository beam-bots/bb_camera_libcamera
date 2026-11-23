# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.CommandTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.Libcamera.Command

  doctest BB.Camera.Libcamera.Command

  defp options(overrides \\ []) do
    Keyword.merge(
      [width: 640, height: 480, frame_rate: 30, executable: "/usr/bin/rpicam-vid"],
      overrides
    )
  end

  defp argv(overrides \\ []) do
    {:ok, command} = Command.new(options(overrides))
    Command.argv(command, 0)
  end

  describe "new/1" do
    test "defaults to the first camera" do
      assert {:ok, %Command{camera: {:index, 0}}} = Command.new(options())
    end

    test "takes a camera by index or by libcamera id" do
      assert {:ok, %Command{camera: {:index, 1}}} = Command.new(options(camera: 1))

      id = "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10"
      assert {:ok, %Command{camera: {:id, ^id}}} = Command.new(options(camera: id))
    end

    test "rejects a camera that is neither" do
      assert {:error, {:invalid_camera, -1}} = Command.new(options(camera: -1))
      assert {:error, {:invalid_camera, ""}} = Command.new(options(camera: ""))
      assert {:error, {:invalid_camera, :left}} = Command.new(options(camera: :left))
      assert {:error, {:invalid_camera, "a\0b"}} = Command.new(options(camera: "a\0b"))
    end

    test "rejects dimensions that are not positive integers" do
      assert {:error, {:invalid_dimension, 0}} = Command.new(options(width: 0))
      assert {:error, {:invalid_dimension, -1}} = Command.new(options(height: -1))
      assert {:error, {:invalid_dimension, "640"}} = Command.new(options(width: "640"))
    end

    test "rejects a frame rate that is not positive" do
      assert {:error, {:invalid_frame_rate, 0}} = Command.new(options(frame_rate: 0))
      assert {:error, {:invalid_frame_rate, {30, 0}}} = Command.new(options(frame_rate: {30, 0}))
    end

    test "rejects flips and buffer counts of the wrong type" do
      assert {:error, {:invalid_flip, "yes"}} = Command.new(options(hflip: "yes"))
      assert {:error, {:invalid_flip, nil}} = Command.new(options(vflip: nil))
      assert {:error, {:invalid_buffer_count, 0}} = Command.new(options(buffer_count: 0))
    end

    test "takes the executable it is given without looking for it" do
      assert {:ok, command} = Command.new(options(executable: "/opt/rpicam/bin/rpicam-vid"))
      assert command.executable == "/opt/rpicam/bin/rpicam-vid"
    end
  end

  describe "argv/2" do
    test "names the camera by the index it was given, whatever was asked for" do
      {:ok, command} =
        Command.new(options(camera: "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10"))

      argv = Command.argv(command, 1)
      assert ["--camera", "1"] == Enum.drop_while(argv, &(&1 != "--camera")) |> Enum.take(2)
      refute Enum.any?(argv, &String.contains?(&1, "i2c@"))
    end

    test "writes unencoded YUV420 to stdout, flushed per frame, with no preview window" do
      argv = argv()

      assert ["--codec", "yuv420"] == Enum.drop_while(argv, &(&1 != "--codec")) |> Enum.take(2)
      assert Enum.take(argv, -3) == ["--flush", "--output", "-"]
      assert "--nopreview" in argv
      refute "--quality" in argv
    end

    test "never asks for anything else on stdout" do
      argv = argv(hflip: true, vflip: true, buffer_count: 2)

      refute "--metadata" in argv
      refute "--keypress" in argv
      assert ["--verbose", "0"] == Enum.drop_while(argv, &(&1 != "--verbose")) |> Enum.take(2)
    end

    test "runs until stopped" do
      assert ["--timeout", "0"] == Enum.drop_while(argv(), &(&1 != "--timeout")) |> Enum.take(2)
    end

    test "passes a rational frame rate as the decimal rpicam-vid parses" do
      argv = argv(frame_rate: {30_000, 1001})

      assert ["--framerate", rate] = Enum.drop_while(argv, &(&1 != "--framerate")) |> Enum.take(2)
      assert {parsed, ""} = Float.parse(rate)
      assert_in_delta parsed, 30_000 / 1001, 1.0e-9
    end

    test "accepts a frame rate as a hertz unit" do
      import BB.Unit

      assert "15.0" in argv(frame_rate: ~u(15 hertz))
    end

    test "only passes flips and buffer counts that were asked for" do
      plain = argv()
      refute "--hflip" in plain
      refute "--vflip" in plain
      refute "--buffer-count" in plain

      flipped = argv(hflip: true, vflip: true, buffer_count: 2)
      assert "--hflip" in flipped
      assert "--vflip" in flipped

      assert ["--buffer-count", "2"] ==
               Enum.drop_while(flipped, &(&1 != "--buffer-count")) |> Enum.take(2)
    end

    test "is all strings" do
      assert Enum.all?(argv(hflip: true, buffer_count: 3), &is_binary/1)
    end
  end
end
