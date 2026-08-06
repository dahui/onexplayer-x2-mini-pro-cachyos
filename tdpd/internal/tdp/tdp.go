// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

// Package tdp applies and reads power limits on Strix Halo.
package tdp

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/config"
	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/smu"
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

// limits is one complete set of power limits, in watts.
type limits struct {
	stapm, fast, slow uint32
}

// known records which entries of a limits are trustworthy. Tracked per limit,
// not per set: after a partial failure some limits are known and some are not,
// and treating the whole set as unknown would re-send the ones that landed.
type known struct {
	stapm, fast, slow bool
}

// Controller applies power limits according to the configured policy.
type Controller struct {
	policy     config.Policy
	hasPMTable bool

	// send issues one limit-setting message. Indirected so tests can drive
	// Apply without an SMU, matching the readFile/writeFile precedent in
	// internal/smu.
	send func(mailbox string, msg, watts uint32) error

	// mu guards everything below it. The daemon applies limits from a
	// background committer goroutine, so the Controller can no longer borrow
	// the D-Bus service's lock the way it used to.
	mu sync.Mutex

	// defaults is the firmware's fast/slow, captured once and persisted. The
	// SMU has no "restore firmware default" message, so once fast/slow have
	// been written the originals are only recoverable from this record (or a
	// reboot).
	defaults     firmwareDefaults
	haveDefaults bool
	defaultsPath string

	// applied records what each limit was last *successfully* set to, so an
	// unchanged limit is not re-sent and a limit whose write failed is retried
	// on the next apply rather than being assumed good.
	applied limits
	known   known

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
		send:         smuSend,
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
	c.mu.Lock()
	defer c.mu.Unlock()

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

// busyRetryDelays is the backoff between attempts when the SMU answers 0xFC.
// Three attempts inside 35 ms, which is affordable now that limits are applied
// from a background goroutine rather than inline on a D-Bus method reply.
var busyRetryDelays = []time.Duration{10 * time.Millisecond, 25 * time.Millisecond}

// smuSend issues one limit-setting message, retrying a busy SMU.
func smuSend(mailbox string, msg, watts uint32) error {
	return retryBusy(rawSend, mailbox, msg, watts)
}

func rawSend(mailbox string, msg, watts uint32) error {
	_, err := smu.SendChecked(mailbox, msg, [6]uint32{watts * 1000})
	return err
}

// retryBusy re-issues a command the SMU answered 0xFC to. Only 0xFC: rejected
// and unknown-command are semantic and would fail identically on a retry.
func retryBusy(send func(mailbox string, msg, watts uint32) error,
	mailbox string, msg, watts uint32,
) error {
	for attempt := 0; ; attempt++ {
		err := send(mailbox, msg, watts)
		if !errors.Is(err, smu.ErrBusy) || attempt >= len(busyRetryDelays) {
			return err
		}
		slog.Debug("SMU busy, retrying", "mailbox", mailbox,
			"msg", fmt.Sprintf("0x%X", msg), "attempt", attempt+1)
		time.Sleep(busyRetryDelays[attempt])
	}
}

// Apply sets the power limits for the given slider value in watts, skipping
// any limit already known to hold that value.
func (c *Controller) Apply(watts uint32) error { return c.apply(watts, false) }

// ApplyForce is Apply without the skip, for cases where the cache cannot be
// trusted to describe the hardware: the --set one-shot, and resume, where the
// firmware has silently reverted to its own limits behind our back.
func (c *Controller) ApplyForce(watts uint32) error { return c.apply(watts, true) }

func (c *Controller) apply(watts uint32, force bool) error {
	if watts < MinWatts || watts > MaxWatts {
		return fmt.Errorf("%d W out of range %d-%d", watts, MinWatts, MaxWatts)
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	want := limits{stapm: watts}
	switch c.policy {
	case config.PolicyAll:
		want.fast, want.slow = watts, watts

	case config.PolicyHeadroom:
		want.slow = watts
		want.fast = watts * headroomNumer / headroomDenom
		if want.fast > MaxWatts {
			want.fast = MaxWatts
		}

	case config.PolicyStapm:
		if !c.haveDefaults {
			// Nothing to restore to, so leave fast/slow alone. On a clean boot
			// they are still the firmware's, which is the intent anyway.
			sent, err := c.sendLimit(&c.applied.stapm, &c.known.stapm,
				want.stapm, force, msgSetStapmLimit)
			if err != nil {
				return err
			}
			c.lastApplied = watts
			if !sent {
				slog.Debug("TDP limit unchanged, not touching the SMU",
					"watts", watts, "policy", c.policy)
				return nil
			}
			slog.Info("applied TDP limit", "watts", watts, "policy", c.policy)
			return nil
		}
		want.fast, want.slow = c.defaults.FastWatts, c.defaults.SlowWatts

	default:
		return fmt.Errorf("unknown policy %q", c.policy)
	}

	// STAPM first in every policy: it is the limit that always applies, so if a
	// later write fails we have still lowered the sustained ceiling rather than
	// raised the burst one.
	sentStapm, err := c.sendLimit(&c.applied.stapm, &c.known.stapm,
		want.stapm, force, msgSetStapmLimit)
	if err != nil {
		return err
	}
	sentFast, err := c.sendLimit(&c.applied.fast, &c.known.fast,
		want.fast, force, msgSetFastLimit)
	if err != nil {
		return fmt.Errorf("setting fast limit to %d W: %w", want.fast, err)
	}
	sentSlow, err := c.sendLimit(&c.applied.slow, &c.known.slow,
		want.slow, force, msgSetSlowLimit)
	if err != nil {
		return fmt.Errorf("setting slow limit to %d W: %w", want.slow, err)
	}

	c.lastApplied = watts
	if !sentStapm && !sentFast && !sentSlow {
		slog.Debug("TDP limit unchanged, not touching the SMU",
			"watts", watts, "policy", c.policy)
		return nil
	}
	slog.Info("applied TDP limit", "watts", watts, "policy", c.policy,
		"fast_w", want.fast, "slow_w", want.slow)
	return nil
}

// sendLimit writes one limit unless that limit is already known to hold the
// value, and records it only once the SMU has accepted the write. A limit whose
// write fails therefore stays marked unknown and is retried next time, instead
// of being assumed good because some other limit in the same apply failed.
//
// Reports whether anything was actually sent.
func (c *Controller) sendLimit(have *uint32, ok *bool, want uint32, force bool, msg uint32) (bool, error) {
	if !force && *ok && *have == want {
		return false, nil
	}
	var err error
	if msg == msgSetStapmLimit {
		err = c.sendStapm(want)
	} else {
		err = c.send(smu.MailboxMP1, msg, want)
	}
	if err != nil {
		return false, err
	}
	*have, *ok = want, true
	return true, nil
}

func (c *Controller) sendStapm(watts uint32) error {
	err := c.send(smu.MailboxMP1, msgSetStapmLimit, watts)
	if err == nil {
		return nil
	}
	// Mirror RyzenAdj: retry on the PSMU mailbox before giving up.
	slog.Warn("STAPM via MP1 failed, retrying on PSMU", "err", err)
	if perr := c.send(smu.MailboxRSMU, msgSetStapmLimitPSMU, watts); perr != nil {
		return fmt.Errorf("setting STAPM limit: MP1: %w; PSMU: %v", err, perr)
	}
	return nil
}

// Current returns the sustained limit the SMU is enforcing, in watts.
//
// This reads the PM table, which is an SMU mailbox command inside the driver,
// not a cheap file read. Keep it off hot paths, and never call it to find out
// what happened after a mailbox command has just failed — use LastApplied.
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
	if w := c.LastApplied(); w != 0 {
		return w
	}
	return MinWatts
}

// LastApplied returns the last value applied successfully, or 0 if none has
// been. Unlike Current it reads only the cache, so it is safe to call after a
// failed SMU command — which is exactly when reaching for the hardware again is
// the worst available move.
func (c *Controller) LastApplied() uint32 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastApplied
}

// Reapply re-sends the last applied limit, for use after resume — SMU limits do
// not survive a suspend cycle. No-op if nothing has been applied yet, so a
// resume before Steam ever set a value leaves the firmware alone.
//
// Forced, and that is load-bearing: after a resume the hardware is back at the
// firmware's limits while our cache still says otherwise, so a deduplicating
// Reapply would skip every write and silently do nothing.
func (c *Controller) Reapply() error {
	w := c.LastApplied()
	if w == 0 {
		return nil
	}
	return c.ApplyForce(w)
}

// Policy reports the active policy.
func (c *Controller) Policy() config.Policy { return c.policy }
