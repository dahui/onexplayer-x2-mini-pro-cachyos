// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

// Package tdp applies and reads power limits on Strix Halo.
package tdp

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"

	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/config"
	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/smu"
)

// SMU MP1 message IDs for Strix Halo (family 0x1A, model 0x70), from RyzenAdj's
// family dispatch in lib/api.c. Arguments are in milliwatts.
const (
	msgSetStapmLimit uint32 = 0x14
	msgSetFastLimit  uint32 = 0x15
	msgSetSlowLimit  uint32 = 0x16

	// RyzenAdj retries STAPM on the PSMU mailbox when MP1 rejects it.
	msgSetStapmLimitPSMU uint32 = 0x31
)

// Range exposed to Steam, in watts, matching what OneXConsole offers.
//
// The vendor app caps at 55 W on battery while allowing 85 W on mains. We
// expose a flat range because TdpLimitMax is declared emits_changed_signal
// ="const" on the D-Bus side, so a maximum that moved when the charger was
// unplugged would break that contract.
const (
	MinWatts uint32 = 10
	MaxWatts uint32 = 85
)

// headroomNumer/Denom give PolicyHeadroom's fast limit as a fraction of the
// slider value.
const (
	headroomNumer = 5
	headroomDenom = 4
)

// firmwareDefaults is what the firmware had set before we touched anything.
// Only meaningful for PolicyStapm, which restores fast/slow to these on every
// apply.
type firmwareDefaults struct {
	FastWatts uint32 `json:"fast_watts"`
	SlowWatts uint32 `json:"slow_watts"`
}

// Controller applies power limits according to the configured policy.
type Controller struct {
	policy     config.Policy
	hasPMTable bool

	// defaults is the firmware's fast/slow, captured once and persisted. The
	// SMU has no "restore firmware default" message, so once fast/slow have
	// been written the originals are only recoverable from this record (or a
	// reboot).
	defaults     firmwareDefaults
	haveDefaults bool
	defaultsPath string

	lastApplied uint32
}

// New returns a Controller. stateDir is where captured firmware defaults are
// persisted; systemd supplies it via StateDirectory=.
func New(policy config.Policy, stateDir string) (*Controller, error) {
	if !smu.Available() {
		return nil, fmt.Errorf("ryzen_smu not loaded: %s is missing (modprobe ryzen_smu)",
			smu.DriverPath+"/"+smu.MailboxMP1)
	}

	c := &Controller{
		policy:       policy,
		hasPMTable:   smu.PMTableAvailable(),
		defaultsPath: filepath.Join(stateDir, "firmware-defaults.json"),
	}

	if c.hasPMTable {
		if ver, err := smu.PMTableVersion(); err == nil {
			slog.Info("PM table available", "version", fmt.Sprintf("0x%X", ver))
		}
		if _, err := smu.ReadLimits(); err != nil {
			slog.Warn("PM table present but unreadable; read-back will use the cached value", "err", err)
			c.hasPMTable = false
		}
	} else {
		slog.Warn("PM table unavailable — read-back will report the last applied value. " +
			"ryzen_smu likely does not know this firmware's table version; see ryzen-smu/ in this repo")
	}

	c.loadOrCaptureDefaults()

	slog.Info("controller ready", "policy", policy,
		"range_w", fmt.Sprintf("%d-%d", MinWatts, MaxWatts))
	return c, nil
}

// loadOrCaptureDefaults restores previously captured firmware limits, or
// captures them now if this is the first run.
//
// Capturing is only valid before anything has written fast/slow. At boot that
// holds — the firmware reapplies its own limits and the daemon starts before
// Steam can ask for anything. It does NOT hold for a mid-session restart, which
// is exactly why the first capture is persisted rather than repeated.
func (c *Controller) loadOrCaptureDefaults() {
	if b, err := os.ReadFile(c.defaultsPath); err == nil {
		if err := json.Unmarshal(b, &c.defaults); err == nil &&
			c.defaults.FastWatts > 0 && c.defaults.SlowWatts > 0 {
			c.haveDefaults = true
			slog.Info("loaded firmware defaults",
				"fast_w", c.defaults.FastWatts, "slow_w", c.defaults.SlowWatts,
				"from", c.defaultsPath)
			return
		}
		slog.Warn("stored firmware defaults unusable, recapturing", "path", c.defaultsPath)
	}

	if !c.hasPMTable {
		slog.Warn("cannot capture firmware defaults without the PM table; " +
			"policy=stapm will leave fast/slow untouched instead of restoring them")
		return
	}

	l, err := smu.ReadLimits()
	if err != nil {
		slog.Warn("failed to capture firmware defaults", "err", err)
		return
	}
	c.defaults = firmwareDefaults{
		FastWatts: uint32(math.Round(float64(l.FastLimit))),
		SlowWatts: uint32(math.Round(float64(l.SlowLimit))),
	}
	c.haveDefaults = true
	slog.Info("captured firmware defaults",
		"fast_w", c.defaults.FastWatts, "slow_w", c.defaults.SlowWatts)

	if err := c.saveDefaults(); err != nil {
		slog.Warn("could not persist firmware defaults; a restart will recapture "+
			"them, which is wrong if limits have been changed since boot", "err", err)
	}
}

func (c *Controller) saveDefaults() error {
	if err := os.MkdirAll(filepath.Dir(c.defaultsPath), 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(c.defaults)
	if err != nil {
		return err
	}
	return os.WriteFile(c.defaultsPath, b, 0o644)
}

// RecaptureDefaults forces a fresh capture, for use after a firmware update.
// Only safe when the current fast/slow really are the firmware's.
func (c *Controller) RecaptureDefaults() error {
	if !c.hasPMTable {
		return fmt.Errorf("cannot recapture without the PM table")
	}
	_ = os.Remove(c.defaultsPath)
	c.haveDefaults = false
	c.loadOrCaptureDefaults()
	if !c.haveDefaults {
		return fmt.Errorf("recapture failed")
	}
	return nil
}

// send issues one limit-setting message.
func send(msg uint32, watts uint32) error {
	_, err := smu.SendChecked(smu.MailboxMP1, msg, [6]uint32{watts * 1000})
	return err
}

// Apply sets the power limits for the given slider value in watts.
func (c *Controller) Apply(watts uint32) error {
	if watts < MinWatts || watts > MaxWatts {
		return fmt.Errorf("%d W out of range %d-%d", watts, MinWatts, MaxWatts)
	}

	// STAPM first in every policy: it is the limit that always applies, so if a
	// later write fails we have still lowered the sustained ceiling rather than
	// raised the burst one.
	if err := c.applyStapm(watts); err != nil {
		return err
	}

	var fast, slow uint32
	switch c.policy {
	case config.PolicyAll:
		fast, slow = watts, watts

	case config.PolicyHeadroom:
		slow = watts
		fast = watts * headroomNumer / headroomDenom
		if fast > MaxWatts {
			fast = MaxWatts
		}

	case config.PolicyStapm:
		if !c.haveDefaults {
			// Nothing to restore to, so leave fast/slow alone. On a clean boot
			// they are still the firmware's, which is the intent anyway.
			c.lastApplied = watts
			slog.Info("applied TDP limit", "watts", watts, "policy", c.policy)
			return nil
		}
		fast, slow = c.defaults.FastWatts, c.defaults.SlowWatts

	default:
		return fmt.Errorf("unknown policy %q", c.policy)
	}

	if err := send(msgSetFastLimit, fast); err != nil {
		return fmt.Errorf("setting fast limit to %d W: %w", fast, err)
	}
	if err := send(msgSetSlowLimit, slow); err != nil {
		return fmt.Errorf("setting slow limit to %d W: %w", slow, err)
	}

	c.lastApplied = watts
	slog.Info("applied TDP limit", "watts", watts, "policy", c.policy,
		"fast_w", fast, "slow_w", slow)
	return nil
}

func (c *Controller) applyStapm(watts uint32) error {
	err := send(msgSetStapmLimit, watts)
	if err == nil {
		return nil
	}
	// Mirror RyzenAdj: retry on the PSMU mailbox before giving up.
	slog.Warn("STAPM via MP1 failed, retrying on PSMU", "err", err)
	if _, perr := smu.SendChecked(smu.MailboxRSMU, msgSetStapmLimitPSMU,
		[6]uint32{watts * 1000}); perr != nil {
		return fmt.Errorf("setting STAPM limit: MP1: %w; PSMU: %v", err, perr)
	}
	return nil
}

// Current returns the sustained limit the SMU is enforcing, in watts.
func (c *Controller) Current() uint32 {
	if c.hasPMTable {
		if l, err := smu.ReadLimits(); err == nil {
			// Round rather than truncate: the firmware reports 31.000002 for a
			// 31 W request, and a value landing just under an integer would
			// otherwise report one watt low.
			w := uint32(math.Round(float64(l.StapmLimit)))
			switch {
			case w < MinWatts:
				return MinWatts
			case w > MaxWatts:
				return MaxWatts
			default:
				return w
			}
		} else {
			slog.Warn("PM table read failed, falling back to the cached value", "err", err)
		}
	}
	if c.lastApplied == 0 {
		return MinWatts
	}
	return c.lastApplied
}

// Reapply re-sends the last applied limit, for use after resume — SMU limits do
// not survive a suspend cycle. No-op if nothing has been applied yet, so a
// resume before Steam ever set a value leaves the firmware alone.
func (c *Controller) Reapply() error {
	if c.lastApplied == 0 {
		return nil
	}
	return c.Apply(c.lastApplied)
}

// Policy reports the active policy.
func (c *Controller) Policy() config.Policy { return c.policy }
