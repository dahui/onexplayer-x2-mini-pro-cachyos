// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

package smu

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
)

// PM table byte offsets. The first entries of the table are stable across
// versions (RyzenAdj relies on the same assumption), and were confirmed on this
// device by writing distinct limits and reading them back:
//
//	offset 0x0  = 31.000002   after MP1 0x14 <- 31000
//	offset 0x8  = 53.000004   after MP1 0x15 <- 53000
//	offset 0x10 = 47.000004   after MP1 0x16 <- 47000
//
// Values are float32 watts, in contrast to the mailbox arguments, which are
// integer milliwatts.
const (
	offStapmLimit = 0x0
	offStapmValue = 0x4
	offFastLimit  = 0x8
	offFastValue  = 0xC
	offSlowLimit  = 0x10
	offSlowValue  = 0x14
)

// Limits is a snapshot of the power limits and their current draw, in watts.
type Limits struct {
	StapmLimit float32
	StapmValue float32
	FastLimit  float32
	FastValue  float32
	SlowLimit  float32
	SlowValue  float32
}

// PMTableAvailable reports whether the driver exposed the PM table. It does not
// on firmware whose table version is absent from ryzen_smu's size table — this
// device needed a patch adding version 0x64010C, see ryzen-smu/ in this repo.
func PMTableAvailable() bool {
	_, err := os.Stat(DriverPath + "/pm_table")
	return err == nil
}

// PMTableVersion returns the firmware's PM table version.
func PMTableVersion() (uint32, error) {
	mu.Lock()
	defer mu.Unlock()

	b, err := readFile(DriverPath + "/pm_table_version")
	if err != nil {
		return 0, fmt.Errorf("reading pm_table_version: %w", err)
	}
	if len(b) < 4 {
		return 0, fmt.Errorf("short pm_table_version: %d bytes", len(b))
	}
	return binary.LittleEndian.Uint32(b[:4]), nil
}

// ReadLimits returns the limits the SMU is currently enforcing.
//
// The driver refreshes the table from the SMU on read (rate-limited to 1 ms
// internally), so no explicit transfer command is needed here.
//
// That refresh is a real mailbox command, not a cheap read — it takes mu for
// the same reason Send does, and it costs about as much. Do not call this on a
// hot path, and never to report that a mailbox command has just failed.
func ReadLimits() (Limits, error) {
	var l Limits

	mu.Lock()
	defer mu.Unlock()

	b, err := readFile(DriverPath + "/pm_table")
	if err != nil {
		return l, fmt.Errorf("reading pm_table: %w", err)
	}
	if len(b) < offSlowValue+4 {
		return l, fmt.Errorf("pm_table too short: %d bytes", len(b))
	}

	f32 := func(off int) float32 {
		return math.Float32frombits(binary.LittleEndian.Uint32(b[off : off+4]))
	}
	l.StapmLimit = f32(offStapmLimit)
	l.StapmValue = f32(offStapmValue)
	l.FastLimit = f32(offFastLimit)
	l.FastValue = f32(offFastValue)
	l.SlowLimit = f32(offSlowLimit)
	l.SlowValue = f32(offSlowValue)

	// A table read that lands outside the real layout tends to produce NaN or
	// wildly out-of-range floats rather than failing outright. Treat the
	// sustained limit as the canary.
	if math.IsNaN(float64(l.StapmLimit)) || l.StapmLimit <= 0 || l.StapmLimit > 500 {
		return l, fmt.Errorf("implausible STAPM limit %v from pm_table — layout may not match this firmware", l.StapmLimit)
	}
	return l, nil
}
