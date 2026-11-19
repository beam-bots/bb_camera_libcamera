# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Libcamera.DevicesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.Libcamera.Devices

  doctest BB.Camera.Libcamera.Devices

  @fake Path.expand("../../../support/fake_rpicam_vid", __DIR__)
  @left "/base/axi/pcie@1000120000/rp1/i2c@88000/imx219@10"
  @right "/base/axi/pcie@1000120000/rp1/i2c@80000/imx219@10"

  describe "list/1" do
    test "reads the cameras from rpicam-vid, including one another process holds" do
      assert {:ok, [left, right]} = Devices.list(executable: @fake)

      assert %{index: 0, id: @left, model: "imx219", description: "3280x2464 10-bit"} = left
      assert %{index: 1, id: @right, model: "imx219"} = right
    end

    test "reports an rpicam-vid that fails" do
      assert {:error, {:list_failed, status, _output}} = Devices.list(executable: "/bin/false")
      assert status != 0
    end
  end

  describe "index_of/2" do
    test "finds two identical sensors apart by the connector in their id" do
      assert {:ok, 0} = Devices.index_of(@left, executable: @fake)
      assert {:ok, 1} = Devices.index_of(@right, executable: @fake)
    end

    test "names every camera it does know when asked for one it doesn't" do
      assert {:error, {:unknown_camera, "/base/nope", [@left, @right]}} =
               Devices.index_of("/base/nope", executable: @fake)
    end
  end

  describe "parse/1" do
    test "finds no cameras in a listing that has none" do
      assert [] == Devices.parse("No cameras available!\n")
    end
  end
end
