// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

// Package smu talks to the AMD System Management Unit through the ryzen_smu
// kernel module's sysfs interface at /sys/kernel/ryzen_smu_drv/.
//
// The mailbox transport originated in z13ctl (github.com/dahui/z13ctl,
// internal/cli/smu.go), where it is released under Apache-2.0. Same author,
// relicensed GPL-2.0 for this repository — Apache-2.0 is not compatible with
// GPL-2.0-only, so the code could not simply be carried across under its
// original terms. Only the transport is reused: z13ctl's TDP code drives ASUS
// platform sysfs (asus-nb-wmi) and does not apply to this device.
//
// All reads and writes are binary little-endian u32, not text.
package smu

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"sync"
)

// DriverPath is the ryzen_smu sysfs root. A var so tests can redirect it.
var DriverPath = "/sys/kernel/ryzen_smu_drv"

// SMU mailbox identifiers, each a sysfs file accepting binary command IDs.
const (
	MailboxMP1  = "mp1_smu_cmd"
	MailboxRSMU = "rsmu_cmd"
)

// Response codes returned by the firmware after a command.
const (
	ReturnOK         uint32 = 0x01
	ReturnFailed     uint32 = 0xFF
	ReturnUnknownCmd uint32 = 0xFE
	ReturnRejected   uint32 = 0xFD
	ReturnBusy       uint32 = 0xFC
)

// Indirected so tests can supply a fake driver. The real driver replaces a
// mailbox file's contents with the firmware response after a command write,
// which plain files cannot emulate.
var (
	readFile  = os.ReadFile
	writeFile = os.WriteFile
)

// mu serializes command sequences. The ryzen_smu driver shares a single
// argument buffer across all mailboxes, so concurrent commands would corrupt
// each other's arguments.
//
// It also covers the PM table reads in pmtable.go, which look like plain file
// reads but are not: pm_table_show calls smu_read_pm_table, which issues an
// RSMU TransferTableSmu2Dram command (rate-limited to 1 ms inside the driver).
// The driver stores every mailbox's response in one global, g_driver.smu_rsp,
// so a concurrent read could hand Send somebody else's response code. Until the
// daemon grew a background committer this was serialized by accident, one layer
// up; it is now serialized on purpose.
var mu sync.Mutex

// ErrBusy reports SMU response 0xFC. It is the only response code worth
// retrying: the firmware was mid-command and the request never took effect.
// Rejected (0xFD) and unknown-command (0xFE) are semantic and would fail again.
var ErrBusy = errors.New("SMU busy (0xFC)")

// Available reports whether the ryzen_smu module is loaded and reachable.
func Available() bool {
	_, err := os.Stat(DriverPath + "/" + MailboxMP1)
	return err == nil
}

// Send issues a command to the given mailbox and returns the response code
// along with the output arguments.
//
// Protocol:
//  1. Write 24 bytes (6 x u32 LE) to smu_args
//  2. Write 4 bytes (u32 LE command ID) to the mailbox file
//  3. Read 4 bytes (u32 LE response code) back from the mailbox file
//  4. Read 24 bytes (6 x u32 LE) from smu_args for response arguments
func Send(mailbox string, cmdID uint32, args [6]uint32) (uint32, [6]uint32, error) {
	mu.Lock()
	defer mu.Unlock()
	return sendLocked(mailbox, cmdID, args)
}

// sendLocked is Send's body, split out so callers already holding mu can reuse
// it without deadlocking on a non-reentrant mutex.
func sendLocked(mailbox string, cmdID uint32, args [6]uint32) (uint32, [6]uint32, error) {
	argsPath := DriverPath + "/smu_args"
	cmdPath := DriverPath + "/" + mailbox

	argsBuf := make([]byte, 24)
	for i, v := range args {
		binary.LittleEndian.PutUint32(argsBuf[i*4:], v)
	}
	if err := writeFile(argsPath, argsBuf, 0o640); err != nil {
		return 0, [6]uint32{}, fmt.Errorf("writing smu_args: %w", err)
	}

	cmdBuf := make([]byte, 4)
	binary.LittleEndian.PutUint32(cmdBuf, cmdID)
	if err := writeFile(cmdPath, cmdBuf, 0o640); err != nil {
		return 0, [6]uint32{}, fmt.Errorf("writing %s: %w", mailbox, err)
	}

	respData, err := readFile(cmdPath)
	if err != nil {
		return 0, [6]uint32{}, fmt.Errorf("reading %s response: %w", mailbox, err)
	}
	if len(respData) < 4 {
		return 0, [6]uint32{}, fmt.Errorf("short response from %s: %d bytes", mailbox, len(respData))
	}
	code := binary.LittleEndian.Uint32(respData[:4])

	var outArgs [6]uint32
	respArgs, err := readFile(argsPath)
	if err != nil {
		return code, outArgs, fmt.Errorf("reading smu_args response: %w", err)
	}
	for i := range outArgs {
		if (i+1)*4 <= len(respArgs) {
			outArgs[i] = binary.LittleEndian.Uint32(respArgs[i*4 : (i+1)*4])
		}
	}
	return code, outArgs, nil
}

// ResponseError turns a non-OK response code into a diagnosable error.
func ResponseError(code uint32) error {
	switch code {
	case ReturnOK:
		return nil
	case ReturnFailed:
		return fmt.Errorf("SMU command failed (0xFF)")
	case ReturnUnknownCmd:
		return fmt.Errorf("SMU unknown command (0xFE) — ensure the amkillam/ryzen_smu " +
			"fork is installed; the leogx9r fork does not support Strix Halo")
	case ReturnRejected:
		return fmt.Errorf("SMU command rejected (0xFD)")
	case ReturnBusy:
		return fmt.Errorf("%w", ErrBusy)
	default:
		return fmt.Errorf("SMU unexpected response: 0x%X", code)
	}
}

// SendChecked issues a command and folds a non-OK response into an error.
func SendChecked(mailbox string, cmdID uint32, args [6]uint32) ([6]uint32, error) {
	code, out, err := Send(mailbox, cmdID, args)
	if err != nil {
		return out, err
	}
	return out, ResponseError(code)
}
