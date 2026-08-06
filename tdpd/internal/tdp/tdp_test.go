// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

package tdp

import (
	"errors"
	"fmt"
	"testing"

	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/config"
	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/smu"
)

// sentCmd is one recorded SMU message.
type sentCmd struct {
	mailbox string
	msg     uint32
	watts   uint32
}

func (s sentCmd) String() string {
	return fmt.Sprintf("%s/0x%X=%dW", s.mailbox, s.msg, s.watts)
}

// recorder is an injectable send that records calls and can be made to fail.
type recorder struct {
	sent []sentCmd
	// fail returns the error to answer a given call with, by message id.
	fail func(msg uint32, nth int) error
	n    int
}

func (r *recorder) send(mailbox string, msg, watts uint32) error {
	r.n++
	if r.fail != nil {
		if err := r.fail(msg, r.n); err != nil {
			return err
		}
	}
	r.sent = append(r.sent, sentCmd{mailbox, msg, watts})
	return nil
}

func (r *recorder) reset() { r.sent = nil }

func newTestController(t *testing.T, policy config.Policy) (*Controller, *recorder) {
	t.Helper()
	r := &recorder{}
	c := &Controller{policy: policy, send: r.send}
	return c, r
}

func wantSent(t *testing.T, r *recorder, want ...sentCmd) {
	t.Helper()
	if len(r.sent) != len(want) {
		t.Fatalf("sent %v, want %v", r.sent, want)
	}
	for i := range want {
		if r.sent[i] != want[i] {
			t.Fatalf("sent %v, want %v", r.sent, want)
		}
	}
}

func TestApplyPolicyAll(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	if err := c.Apply(40); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetStapmLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetFastLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 40},
	)
}

func TestApplyPolicyHeadroom(t *testing.T) {
	c, r := newTestController(t, config.PolicyHeadroom)
	if err := c.Apply(40); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	// fast = 40 * 5/4 = 50
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetStapmLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetFastLimit, 50},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 40},
	)
}

func TestApplyPolicyHeadroomClampsFast(t *testing.T) {
	c, r := newTestController(t, config.PolicyHeadroom)
	// 80 * 5/4 = 100, above MaxWatts.
	if err := c.Apply(80); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetStapmLimit, 80},
		sentCmd{smu.MailboxMP1, msgSetFastLimit, MaxWatts},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 80},
	)
}

func TestApplyPolicyStapmRestoresDefaults(t *testing.T) {
	c, r := newTestController(t, config.PolicyStapm)
	c.defaults = firmwareDefaults{FastWatts: 100, SlowWatts: 85}
	c.haveDefaults = true

	if err := c.Apply(30); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetStapmLimit, 30},
		sentCmd{smu.MailboxMP1, msgSetFastLimit, 100},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 85},
	)
}

func TestApplyPolicyStapmWithoutDefaultsLeavesFastSlowAlone(t *testing.T) {
	c, r := newTestController(t, config.PolicyStapm)
	if err := c.Apply(30); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	wantSent(t, r, sentCmd{smu.MailboxMP1, msgSetStapmLimit, 30})

	// And the skip still works on that path.
	r.reset()
	if err := c.Apply(30); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	wantSent(t, r)
}

// TestApplyDedupeSkipsUnchanged is the other half of the freeze fix: Steam
// repeats the current value and that must not reach the SMU at all.
func TestApplyDedupeSkipsUnchanged(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	if err := c.Apply(40); err != nil {
		t.Fatalf("first Apply: %v", err)
	}
	if len(r.sent) != 3 {
		t.Fatalf("first apply sent %v, want 3 commands", r.sent)
	}

	r.reset()
	for range 5 { // the observed burst
		if err := c.Apply(40); err != nil {
			t.Fatalf("repeat Apply: %v", err)
		}
	}
	wantSent(t, r)
}

// TestApplyPerLimitSkip: under headroom the fast limit clamps, so consecutive
// high values share it and it must not be re-sent.
func TestApplyPerLimitSkip(t *testing.T) {
	c, r := newTestController(t, config.PolicyHeadroom)
	if err := c.Apply(70); err != nil { // fast clamps to 85
		t.Fatalf("Apply(70): %v", err)
	}
	r.reset()
	if err := c.Apply(80); err != nil { // fast clamps to 85 again
		t.Fatalf("Apply(80): %v", err)
	}
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetStapmLimit, 80},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 80},
	)
}

// TestApplyPartialFailureRetriesOnlyFailedLimit is what justifies tracking each
// limit separately: a limit whose write failed must not be assumed good.
func TestApplyPartialFailureRetriesOnlyFailedLimit(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)

	boom := errors.New("SMU said no")
	failedOnce := false
	r.fail = func(msg uint32, _ int) error {
		if msg == msgSetFastLimit && !failedOnce {
			failedOnce = true
			return boom
		}
		return nil
	}

	if err := c.Apply(40); !errors.Is(err, boom) {
		t.Fatalf("Apply returned %v, want %v", err, boom)
	}
	// STAPM landed; fast failed; slow was never attempted.
	wantSent(t, r, sentCmd{smu.MailboxMP1, msgSetStapmLimit, 40})

	r.reset()
	if err := c.Apply(40); err != nil {
		t.Fatalf("retry Apply: %v", err)
	}
	// STAPM is already correct and must be skipped; fast and slow must not be.
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetFastLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 40},
	)
}

func TestApplyFailureLeavesLastAppliedAlone(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	if err := c.Apply(40); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	// Fail STAPM on both mailboxes, or the PSMU fallback would rescue it.
	boom := errors.New("SMU said no")
	r.fail = func(msg uint32, _ int) error {
		if msg == msgSetStapmLimit || msg == msgSetStapmLimitPSMU {
			return boom
		}
		return nil
	}
	if err := c.Apply(50); err == nil {
		t.Fatal("Apply(50) succeeded, want failure")
	}
	if got := c.LastApplied(); got != 40 {
		t.Errorf("LastApplied is %d, want 40 — the failed value must not be recorded", got)
	}
}

func TestApplyForceIgnoresDedupe(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	if err := c.Apply(40); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	r.reset()
	if err := c.ApplyForce(40); err != nil {
		t.Fatalf("ApplyForce: %v", err)
	}
	wantSent(t, r,
		sentCmd{smu.MailboxMP1, msgSetStapmLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetFastLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 40},
	)
}

// TestReapplyForcesAfterResume: the hardware has reverted to firmware limits
// but the cache has not, so a deduplicating reapply would be a silent no-op.
func TestReapplyForcesAfterResume(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	if err := c.Apply(40); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	r.reset()
	if err := c.Reapply(); err != nil {
		t.Fatalf("Reapply: %v", err)
	}
	if len(r.sent) != 3 {
		t.Fatalf("Reapply sent %v, want all three limits re-sent", r.sent)
	}
}

func TestReapplyBeforeAnyApplyIsNoOp(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	if err := c.Reapply(); err != nil {
		t.Fatalf("Reapply: %v", err)
	}
	wantSent(t, r)
}

func TestApplyOutOfRange(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	for _, w := range []uint32{0, MinWatts - 1, MaxWatts + 1, 1000} {
		if err := c.Apply(w); err == nil {
			t.Errorf("Apply(%d) succeeded, want a range error", w)
		}
	}
	wantSent(t, r)
}

func TestApplyUnknownPolicy(t *testing.T) {
	c, _ := newTestController(t, config.Policy("nonsense"))
	if err := c.Apply(40); err == nil {
		t.Fatal("Apply with an unknown policy succeeded, want an error")
	}
}

// TestStapmFallsBackToPSMU mirrors RyzenAdj: MP1 failure retries on PSMU.
func TestStapmFallsBackToPSMU(t *testing.T) {
	c, r := newTestController(t, config.PolicyAll)
	r.fail = func(msg uint32, _ int) error {
		if msg == msgSetStapmLimit {
			return errors.New("MP1 rejected")
		}
		return nil
	}
	if err := c.Apply(40); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	wantSent(t, r,
		sentCmd{smu.MailboxRSMU, msgSetStapmLimitPSMU, 40},
		sentCmd{smu.MailboxMP1, msgSetFastLimit, 40},
		sentCmd{smu.MailboxMP1, msgSetSlowLimit, 40},
	)
}

// TestSmuSendRetriesOnlyBusy checks the retry policy: 0xFC is transient, the
// other failure codes are semantic and would just fail again.
func TestSmuSendRetriesOnlyBusy(t *testing.T) {
	tests := []struct {
		name         string
		err          error
		failures     int
		wantAttempts int
		wantErr      bool
	}{
		{"busy twice then ok", smu.ErrBusy, 2, 3, false},
		{"busy always", smu.ErrBusy, 99, len(busyRetryDelays) + 1, true},
		{"rejected is not retried", errors.New("SMU command rejected (0xFD)"), 99, 1, true},
		{"succeeds first time", nil, 0, 1, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			attempts := 0
			send := func(_ string, _, _ uint32) error {
				attempts++
				if attempts <= tc.failures {
					return fmt.Errorf("wrapped: %w", tc.err)
				}
				return nil
			}
			err := retryBusy(send, smu.MailboxMP1, msgSetStapmLimit, 40)
			if (err != nil) != tc.wantErr {
				t.Errorf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if attempts != tc.wantAttempts {
				t.Errorf("made %d attempts, want %d", attempts, tc.wantAttempts)
			}
		})
	}
}
