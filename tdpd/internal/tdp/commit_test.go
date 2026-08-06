// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

package tdp

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// commit is one recorded call into the fake hardware.
type commit struct {
	watts  uint32
	forced bool
	at     time.Time
}

type fakeApplier struct {
	mu      sync.Mutex
	calls   []commit
	last    uint32
	err     error // returned by Apply/ApplyForce when set
	commits chan commit
}

func newFakeApplier() *fakeApplier {
	return &fakeApplier{commits: make(chan commit, 64)}
}

func (f *fakeApplier) record(watts uint32, forced bool) error {
	f.mu.Lock()
	c := commit{watts: watts, forced: forced, at: time.Now()}
	f.calls = append(f.calls, c)
	err := f.err
	if err == nil {
		f.last = watts
	}
	f.mu.Unlock()
	f.commits <- c
	return err
}

func (f *fakeApplier) Apply(w uint32) error      { return f.record(w, false) }
func (f *fakeApplier) ApplyForce(w uint32) error { return f.record(w, true) }
func (f *fakeApplier) Reapply() error            { return f.record(f.LastApplied(), true) }

func (f *fakeApplier) LastApplied() uint32 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.last
}

func (f *fakeApplier) recorded() []commit {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]commit(nil), f.calls...)
}

// newTestCommitter builds a Committer with timings scaled down so tests finish
// quickly. Every assertion is on a channel receive rather than a sleep, so the
// short durations do not make the tests timing-fragile.
func newTestCommitter(t *testing.T, f *fakeApplier) *Committer {
	t.Helper()
	c := &Committer{
		ctl:         f,
		delay:       20 * time.Millisecond,
		maxWait:     200 * time.Millisecond,
		minInterval: 10 * time.Millisecond,
	}
	c.start()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = c.Close(ctx)
	})
	return c
}

// waitCommit returns the next commit, failing the test if none arrives.
func waitCommit(t *testing.T, f *fakeApplier) commit {
	t.Helper()
	select {
	case c := <-f.commits:
		return c
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for a commit")
		return commit{}
	}
}

// expectNoCommit fails if anything commits within d.
func expectNoCommit(t *testing.T, f *fakeApplier, d time.Duration) {
	t.Helper()
	select {
	case c := <-f.commits:
		t.Fatalf("unexpected commit of %d W", c.watts)
	case <-time.After(d):
	}
}

// TestCoalescesDragBurst is the regression test for the reported bug: dragging
// the slider must reach hardware once, at the value the user settled on.
func TestCoalescesDragBurst(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	for w := uint32(10); w <= 85; w++ {
		c.Request(w)
	}

	got := waitCommit(t, f)
	if got.watts != 85 {
		t.Errorf("committed %d W, want 85 W (the settled value)", got.watts)
	}
	expectNoCommit(t, f, 100*time.Millisecond)

	if n := len(f.recorded()); n != 1 {
		t.Errorf("76 requests produced %d commits, want 1", n)
	}
}

// TestCoalescesIdenticalBurst reproduces what the journal actually showed:
// Steam emitting five Sets for one value inside 10 ms.
func TestCoalescesIdenticalBurst(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	for range 5 {
		c.Request(40)
		time.Sleep(2 * time.Millisecond)
	}

	if got := waitCommit(t, f); got.watts != 40 {
		t.Errorf("committed %d W, want 40 W", got.watts)
	}
	expectNoCommit(t, f, 100*time.Millisecond)
}

// TestMaxWaitBoundsContinuousInput checks a slow but unending drag still moves
// the hardware rather than appearing dead.
func TestMaxWaitBoundsContinuousInput(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	start := time.Now()
	done := time.After(500 * time.Millisecond)
	w := uint32(10)
loop:
	for {
		select {
		case <-done:
			break loop
		default:
		}
		c.Request(w)
		if w++; w > 85 {
			w = 10
		}
		time.Sleep(5 * time.Millisecond)
	}

	got := f.recorded()
	if len(got) < 2 {
		t.Fatalf("continuous input for 500ms produced %d commits, want >= 2", len(got))
	}
	// The first commit must land within maxWait of the first request, not be
	// postponed indefinitely by the trailing delay resetting.
	if d := got[0].at.Sub(start); d > c.maxWait+100*time.Millisecond {
		t.Errorf("first commit took %v, want <= maxWait (%v) plus slack", d, c.maxWait)
	}
}

// TestMinIntervalFloor checks the hard ceiling on SMU traffic holds.
func TestMinIntervalFloor(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	for i := range 20 {
		c.Request(uint32(20 + i))
		time.Sleep(15 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)

	got := f.recorded()
	for i := 1; i < len(got); i++ {
		if gap := got[i].at.Sub(got[i-1].at); gap < c.minInterval {
			t.Errorf("commits %d and %d are %v apart, want >= %v",
				i-1, i, gap, c.minInterval)
		}
	}
}

func TestCloseFlushesPending(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	c.Request(55)
	// Close well inside the settle delay, so the value is still pending.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Close(ctx); err != nil {
		t.Fatalf("Close: %v", err)
	}

	got := f.recorded()
	if len(got) != 1 || got[0].watts != 55 {
		t.Fatalf("recorded %+v, want a single commit of 55 W", got)
	}
}

func TestCloseIdleCommitsNothing(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Close(ctx); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := f.recorded(); len(got) != 0 {
		t.Errorf("recorded %+v, want nothing", got)
	}
}

func TestCloseReportsFlushError(t *testing.T) {
	f := newFakeApplier()
	want := errors.New("SMU said no")
	f.err = want
	c := newTestCommitter(t, f)

	c.Request(55)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Close(ctx); !errors.Is(err, want) {
		t.Errorf("Close returned %v, want %v", err, want)
	}
}

// TestReapplyForces is the resume path: the hardware has silently reverted to
// firmware limits, so the write must not be skipped as a no-op.
func TestReapplyForces(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	c.Request(40)
	waitCommit(t, f)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Reapply(ctx); err != nil {
		t.Fatalf("Reapply: %v", err)
	}

	got := f.recorded()
	if len(got) != 2 {
		t.Fatalf("recorded %d commits, want 2", len(got))
	}
	if !got[1].forced {
		t.Error("reapply did not force; a deduplicating apply would silently do nothing after resume")
	}
	if got[1].watts != 40 {
		t.Errorf("reapplied %d W, want 40 W", got[1].watts)
	}
}

// TestReapplyPrefersPendingValue: a value the user just chose is newer than
// anything already committed.
func TestReapplyPrefersPendingValue(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	c.Request(65) // still inside the settle window
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Reapply(ctx); err != nil {
		t.Fatalf("Reapply: %v", err)
	}

	got := f.recorded()
	if len(got) != 1 || got[0].watts != 65 || !got[0].forced {
		t.Fatalf("recorded %+v, want one forced commit of 65 W", got)
	}

	// The pending value was consumed by the reapply, so the settle timer that
	// is still armed must find nothing left to commit.
	<-f.commits // the reapply's own commit
	expectNoCommit(t, f, 100*time.Millisecond)
}

func TestRequestAfterCloseDoesNotBlock(t *testing.T) {
	f := newFakeApplier()
	c := newTestCommitter(t, f)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Close(ctx); err != nil {
		t.Fatalf("Close: %v", err)
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 10 {
			c.Request(40)
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Request blocked after Close")
	}
}

// TestOnCommitReportsFailure checks the D-Bus layer gets told when a commit
// fails, since that is its only route to correcting the exported property.
func TestOnCommitReportsFailure(t *testing.T) {
	f := newFakeApplier()
	want := errors.New("SMU busy")
	f.err = want
	c := newTestCommitter(t, f)

	type result struct {
		watts uint32
		err   error
	}
	results := make(chan result, 4)
	c.OnCommit(func(w uint32, err error) { results <- result{w, err} })

	c.Request(45)
	select {
	case got := <-results:
		if got.watts != 45 || !errors.Is(got.err, want) {
			t.Errorf("onCommit got (%d, %v), want (45, %v)", got.watts, got.err, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("onCommit was never called")
	}
}
