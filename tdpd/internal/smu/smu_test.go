// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

package smu

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"os"
	"strings"
	"testing"
)

// fakeDriver stands in for ryzen_smu's sysfs. The real driver replaces a
// mailbox file's contents with the firmware response after a command write,
// which plain files cannot emulate — hence the readFile/writeFile indirection.
type fakeDriver struct {
	log   []string
	args  []byte
	rsp   uint32
	wrErr error
}

func (f *fakeDriver) install(t *testing.T) {
	t.Helper()
	oldRead, oldWrite, oldPath := readFile, writeFile, DriverPath
	t.Cleanup(func() { readFile, writeFile, DriverPath = oldRead, oldWrite, oldPath })

	DriverPath = "/fake"
	f.args = make([]byte, 24)
	f.rsp = ReturnOK

	writeFile = func(name string, data []byte, _ os.FileMode) error {
		f.log = append(f.log, fmt.Sprintf("write %s %d", base(name), len(data)))
		if f.wrErr != nil {
			return f.wrErr
		}
		if base(name) == "smu_args" {
			f.args = append([]byte(nil), data...)
		}
		return nil
	}
	readFile = func(name string) ([]byte, error) {
		f.log = append(f.log, "read "+base(name))
		switch base(name) {
		case "smu_args":
			return f.args, nil
		default:
			b := make([]byte, 4)
			binary.LittleEndian.PutUint32(b, f.rsp)
			return b, nil
		}
	}
}

func base(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
}

// TestSendProtocolOrder pins the four-step mailbox protocol. Getting the order
// wrong corrupts an in-flight command rather than failing cleanly.
func TestSendProtocolOrder(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)

	code, _, err := Send(MailboxMP1, 0x14, [6]uint32{31000})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if code != ReturnOK {
		t.Errorf("code = 0x%X, want 0x%X", code, ReturnOK)
	}

	want := []string{
		"write smu_args 24",   // 6 x u32 LE argument block
		"write mp1_smu_cmd 4", // u32 LE command id
		"read mp1_smu_cmd",    // response code
		"read smu_args",       // response arguments
	}
	if len(f.log) != len(want) {
		t.Fatalf("call sequence %v, want %v", f.log, want)
	}
	for i := range want {
		if f.log[i] != want[i] {
			t.Fatalf("call sequence %v, want %v", f.log, want)
		}
	}

	// Arguments are little-endian u32 in milliwatts, arg0 first.
	if got := binary.LittleEndian.Uint32(f.args[:4]); got != 31000 {
		t.Errorf("arg0 = %d, want 31000", got)
	}
	for i := 1; i < 6; i++ {
		if got := binary.LittleEndian.Uint32(f.args[i*4 : (i+1)*4]); got != 0 {
			t.Errorf("arg%d = %d, want 0", i, got)
		}
	}
}

func TestSendUsesRequestedMailbox(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)

	if _, _, err := Send(MailboxRSMU, 0x31, [6]uint32{40000}); err != nil {
		t.Fatalf("Send: %v", err)
	}
	for _, entry := range f.log {
		if strings.Contains(entry, "mp1_smu_cmd") {
			t.Fatalf("RSMU command touched the MP1 mailbox: %v", f.log)
		}
	}
}

func TestSendPropagatesWriteError(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)
	f.wrErr = errors.New("ENOSPC")

	if _, _, err := Send(MailboxMP1, 0x14, [6]uint32{31000}); err == nil {
		t.Fatal("Send succeeded despite a write error")
	}
}

func TestSendCheckedFoldsResponseCode(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)
	f.rsp = ReturnFailed

	if _, err := SendChecked(MailboxMP1, 0x14, [6]uint32{31000}); err == nil {
		t.Fatal("SendChecked accepted a 0xFF response")
	}
}

// TestResponseErrorBusyIsErrBusy: the retry logic in internal/tdp keys off
// this, and only this.
func TestResponseErrorBusyIsErrBusy(t *testing.T) {
	if err := ResponseError(ReturnBusy); !errors.Is(err, ErrBusy) {
		t.Errorf("ResponseError(0xFC) = %v, want it to wrap ErrBusy", err)
	}
	for _, code := range []uint32{ReturnFailed, ReturnUnknownCmd, ReturnRejected, 0x99} {
		err := ResponseError(code)
		if err == nil {
			t.Errorf("ResponseError(0x%X) = nil, want an error", code)
			continue
		}
		if errors.Is(err, ErrBusy) {
			t.Errorf("ResponseError(0x%X) wraps ErrBusy; only 0xFC may be retried", code)
		}
	}
	if err := ResponseError(ReturnOK); err != nil {
		t.Errorf("ResponseError(0x01) = %v, want nil", err)
	}
}

func TestReadLimits(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)

	// The values measured on this device when 31/53/47 W were written.
	table := make([]byte, 0x18)
	put := func(off int, v float32) {
		binary.LittleEndian.PutUint32(table[off:], math.Float32bits(v))
	}
	put(offStapmLimit, 31.000002)
	put(offStapmValue, 12.5)
	put(offFastLimit, 53.000004)
	put(offFastValue, 20)
	put(offSlowLimit, 47.000004)
	put(offSlowValue, 18)

	readFile = func(string) ([]byte, error) { return table, nil }

	l, err := ReadLimits()
	if err != nil {
		t.Fatalf("ReadLimits: %v", err)
	}
	if l.StapmLimit != 31.000002 || l.FastLimit != 53.000004 || l.SlowLimit != 47.000004 {
		t.Errorf("limits = %+v, want 31/53/47 W", l)
	}
}

// TestReadLimitsRejectsImplausible: a layout mismatch produces NaN or nonsense
// rather than an error, so the sustained limit is used as a canary.
func TestReadLimitsRejectsImplausible(t *testing.T) {
	tests := map[string]float32{
		"NaN":      float32(math.NaN()),
		"zero":     0,
		"negative": -5,
		"absurd":   9000,
	}
	for name, stapm := range tests {
		t.Run(name, func(t *testing.T) {
			f := &fakeDriver{}
			f.install(t)

			table := make([]byte, 0x18)
			binary.LittleEndian.PutUint32(table[offStapmLimit:], math.Float32bits(stapm))
			readFile = func(string) ([]byte, error) { return table, nil }

			if _, err := ReadLimits(); err == nil {
				t.Errorf("ReadLimits accepted a STAPM limit of %v", stapm)
			}
		})
	}
}

func TestReadLimitsRejectsShortTable(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)
	readFile = func(string) ([]byte, error) { return make([]byte, 8), nil }

	if _, err := ReadLimits(); err == nil {
		t.Fatal("ReadLimits accepted a table too short to contain the limits")
	}
}

func TestPMTableVersion(t *testing.T) {
	f := &fakeDriver{}
	f.install(t)
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, 0x64010C) // this device's firmware
	readFile = func(string) ([]byte, error) { return b, nil }

	got, err := PMTableVersion()
	if err != nil {
		t.Fatalf("PMTableVersion: %v", err)
	}
	if got != 0x64010C {
		t.Errorf("version = 0x%X, want 0x64010C", got)
	}
}
