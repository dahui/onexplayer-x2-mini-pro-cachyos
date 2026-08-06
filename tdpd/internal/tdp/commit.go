// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

package tdp

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"
)

// Debounce parameters. Deliberately not configurable: settle = 0 restores the
// behaviour these exist to prevent, and there is no legitimate reason to tune
// them.
//
// The daemon shares the SMU mailbox with amdgpu, which polls it constantly
// while a game is running, and neither side arbitrates. Every command we send
// is a chance to collide, so the fix is to send far fewer of them.
//
//   - settleDelay: commit once the user stops moving the slider. 250 ms is 25x
//     the 10 ms burst Steam was observed emitting for a single value, and sits
//     above Steam's D-pad repeat interval so held-direction nudging coalesces
//     too. TDP is not latency-critical; the thermal response is seconds-scale
//     whatever we do here.
//   - settleMax: a slow but continuous drag would otherwise never settle and
//     the hardware would appear dead. Bounds that at roughly one commit/second.
//   - minInterval: a hard floor between commits, so the ceiling on SMU traffic
//     is provable (<= 6.7 commits/s) rather than contingent on Steam behaving.
const (
	settleDelay = 250 * time.Millisecond
	settleMax   = 1000 * time.Millisecond
	minInterval = 150 * time.Millisecond
)

// applier is the hardware-facing half of a Committer, indirected so the
// debounce can be tested without an SMU.
type applier interface {
	Apply(watts uint32) error
	ApplyForce(watts uint32) error
	Reapply() error
	LastApplied() uint32
}

// Committer coalesces a stream of requested TDP values into occasional
// hardware commits.
//
// A single goroutine owns the commit path, which is what makes "the SMU is
// touched from one place" structurally true rather than a comment, and lets
// flush-on-shutdown be a case in the same select instead of a race against a
// firing timer.
type Committer struct {
	ctl applier

	delay       time.Duration
	maxWait     time.Duration
	minInterval time.Duration

	// onCommit, if set, is called from the committer goroutine after every
	// commit attempt. It must not block.
	onCommit func(watts uint32, err error)

	// mu guards the pending request. The request slot is state rather than a
	// channel payload so that Request never blocks: a request arriving while
	// the goroutine is stuck in a slow SMU write overwrites the slot and rings
	// the doorbell instead of queueing behind it. Blocking there would stall a
	// D-Bus dispatch goroutine while godbus holds its properties lock, which
	// would wedge every Get on the object — the exact coupling this whole
	// change exists to break.
	mu          sync.Mutex
	pending     uint32
	havePending bool
	firstReq    time.Time

	wake      chan struct{} // doorbell, buffered 1
	reapplyCh chan chan error
	stopCh    chan struct{}
	stopped   chan struct{}
	stopOnce  sync.Once
	flushErr  error // written before stopped closes
}

// NewCommitter returns a started Committer using the production timings.
func NewCommitter(ctl applier) *Committer {
	c := &Committer{
		ctl:         ctl,
		delay:       settleDelay,
		maxWait:     settleMax,
		minInterval: minInterval,
	}
	c.start()
	return c
}

// start initialises the channels and launches the goroutine. Split out so
// tests can build a Committer literal with their own timings.
func (c *Committer) start() {
	c.wake = make(chan struct{}, 1)
	c.reapplyCh = make(chan chan error)
	c.stopCh = make(chan struct{})
	c.stopped = make(chan struct{})
	go c.run()
}

// OnCommit registers a callback invoked from the committer goroutine after
// every commit attempt. It must not block, and must be set before the first
// Request.
func (c *Committer) OnCommit(fn func(watts uint32, err error)) { c.onCommit = fn }

// Request asks for watts to be applied once the value settles. It never blocks
// and never fails; the outcome arrives via onCommit and the journal.
//
// Requests supersede one another: only the most recent value is committed.
func (c *Committer) Request(watts uint32) {
	c.mu.Lock()
	if !c.havePending {
		c.firstReq = time.Now()
	}
	c.pending, c.havePending = watts, true
	c.mu.Unlock()

	select {
	case c.wake <- struct{}{}:
	default: // doorbell already rung; the goroutine will read the slot
	}
}

// take returns the pending value and clears the slot.
func (c *Committer) take() (uint32, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	w, ok := c.pending, c.havePending
	c.havePending = false
	return w, ok
}

// deadline returns when the pending value should be committed, given the last
// commit time. Only meaningful while a request is pending.
func (c *Committer) deadline(lastCommit time.Time) time.Time {
	c.mu.Lock()
	first := c.firstReq
	c.mu.Unlock()

	d := time.Now().Add(c.delay)
	if ceil := first.Add(c.maxWait); ceil.Before(d) {
		d = ceil // a continuous drag must still move the hardware sometimes
	}
	if floor := lastCommit.Add(c.minInterval); floor.After(d) {
		d = floor // ...but never faster than the rate floor
	}
	return d
}

func (c *Committer) run() {
	defer close(c.stopped)

	// go.mod requires Go 1.26, so Reset needs no Stop/drain dance: since 1.23 a
	// stopped or reset timer never delivers a stale value. Leaving timerC nil
	// while idle is what keeps the select blocked with nothing pending.
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	var timerC <-chan time.Time

	var lastCommit time.Time

	commit := func() {
		timerC = nil
		w, ok := c.take()
		if !ok {
			return
		}
		err := c.ctl.Apply(w)
		lastCommit = time.Now()
		if err != nil {
			slog.Error("failed to apply TDP limit", "watts", w, "err", err)
		}
		if c.onCommit != nil {
			c.onCommit(w, err)
		}
	}

	for {
		select {
		case <-c.wake:
			wait := time.Until(c.deadline(lastCommit))
			if wait < 0 {
				wait = 0
			}
			timer.Reset(wait)
			timerC = timer.C

		case <-timerC:
			commit()

		case reply := <-c.reapplyCh:
			// A pending value is newer than anything the controller has
			// recorded, so prefer it — but force it, since after a resume the
			// hardware no longer matches the cache.
			timerC = nil
			var err error
			if w, ok := c.take(); ok {
				err = c.ctl.ApplyForce(w)
			} else {
				err = c.ctl.Reapply()
			}
			lastCommit = time.Now()
			reply <- err

		case <-c.stopCh:
			// Flush rather than drop: the user's last slider position is
			// already showing in Steam's UI, and discarding it leaves that
			// display silently wrong until something sets TDP again.
			timerC = nil
			if w, ok := c.take(); ok {
				if err := c.ctl.Apply(w); err != nil {
					c.flushErr = err
				}
			}
			return
		}
	}
}

// Reapply forces the controller's last value back onto the hardware, for use
// after resume. It waits for the result.
func (c *Committer) Reapply(ctx context.Context) error {
	reply := make(chan error, 1)
	select {
	case c.reapplyCh <- reply:
	case <-c.stopped:
		return errors.New("committer stopped")
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case err := <-reply:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Close stops the committer, flushing any pending value first.
//
// ctx bounds how long we wait, not how long the write takes. A goroutine
// blocked inside an uninterruptible write() to the ryzen_smu mailbox cannot be
// cancelled from Go, and process exit will still wait on it; the timeout only
// stops us from waiting politely on a wedged SMU.
func (c *Committer) Close(ctx context.Context) error {
	c.stopOnce.Do(func() { close(c.stopCh) })
	select {
	case <-c.stopped:
		return c.flushErr
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Reapply on the Controller is what the committer calls when nothing is
// pending; asserting the interface here keeps that wiring honest.
var _ applier = (*Controller)(nil)
