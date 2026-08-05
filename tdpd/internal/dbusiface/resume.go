// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

package dbusiface

import (
	"context"
	"log/slog"

	"github.com/godbus/dbus/v5"
)

// WatchResume reapplies the current limit after the system wakes from sleep.
// SMU power limits do not survive a suspend cycle, so without this the machine
// silently returns to firmware defaults while Steam still shows the old value.
//
// Follows the same logind PrepareForSleep pattern as z13ctl's
// internal/daemon/resume.go.
func (s *Service) WatchResume(ctx context.Context) {
	const rule = "type='signal',interface='org.freedesktop.login1.Manager'," +
		"member='PrepareForSleep',path='/org/freedesktop/login1'"

	if call := s.conn.BusObject().Call(
		"org.freedesktop.DBus.AddMatch", 0, rule); call.Err != nil {
		slog.Warn("cannot subscribe to logind sleep signals; "+
			"TDP will not be reapplied after resume", "err", call.Err)
		return
	}

	ch := make(chan *dbus.Signal, 8)
	s.conn.Signal(ch)
	slog.Info("resume watcher started")

	for {
		select {
		case <-ctx.Done():
			return
		case sig, ok := <-ch:
			if !ok {
				return
			}
			if sig.Name != "org.freedesktop.login1.Manager.PrepareForSleep" ||
				len(sig.Body) == 0 {
				continue
			}
			sleeping, ok := sig.Body[0].(bool)
			if !ok {
				continue
			}
			if sleeping {
				slog.Info("system entering sleep")
				continue
			}

			slog.Info("system resumed, reapplying TDP limit")
			s.mu.Lock()
			err := s.ctl.Reapply()
			s.mu.Unlock()
			if err != nil {
				slog.Error("failed to reapply TDP after resume", "err", err)
			}
			s.Sync()
		}
	}
}
