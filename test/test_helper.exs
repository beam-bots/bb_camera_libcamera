# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# `:rpicam` tests run `rpicam-vid` against a real camera, so they only pass on
# a Raspberry Pi with one attached.
ExUnit.start(exclude: [:rpicam])
