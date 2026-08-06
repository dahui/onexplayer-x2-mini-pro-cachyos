// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

// Package dbusiface exposes com.steampowered.SteamOSManager1.TdpLimit1 on the
// system bus so steamos-manager can proxy Steam's TDP slider to us.
//
// steamos-manager picks the remote up from a registration file in
// /etc/steamos-manager/remotes.d/ naming this bus name and object path. The
// interface contract comes from steamos-manager's own source: TdpLimit is a
// read-write u32 in watts, TdpLimitMin/Max are read-only u32 declared
// emits_changed_signal="const".
package dbusiface

import (
	"fmt"
	"log/slog"
	"sync/atomic"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/prop"

	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/tdp"
)

const (
	BusName    = "io.aletheia.OxpTdp1"
	ObjectPath = "/io/aletheia/OxpTdp1"
	Interface  = "com.steampowered.SteamOSManager1.TdpLimit1"
)

// Service owns the D-Bus surface. It holds no lock of its own: the controller
// guards its own state, and the committer owns the only goroutine that touches
// hardware.
type Service struct {
	ctl  *tdp.Controller
	com  *tdp.Committer
	conn *dbus.Conn
	prop *prop.Properties

	// announced is the value clients currently believe is in force, i.e. what
	// godbus last emitted. Tracked so a corrective emit after a failed commit
	// can be suppressed when it would say nothing new.
	announced atomic.Uint32
}

// Export claims the bus name and publishes the interface.
func Export(ctl *tdp.Controller, com *tdp.Committer) (*Service, error) {
	conn, err := dbus.SystemBus()
	if err != nil {
		return nil, fmt.Errorf("connecting to system bus: %w", err)
	}

	s := &Service{ctl: ctl, com: com, conn: conn}

	current := ctl.Current()
	s.announced.Store(current)
	com.OnCommit(s.onCommitted)

	propSpec := map[string]map[string]*prop.Prop{
		Interface: {
			"TdpLimit": {
				Value:    current,
				Writable: true,
				Emit:     prop.EmitTrue,
				Callback: s.onSetTdpLimit,
			},
			"TdpLimitMin": {
				Value:    tdp.MinWatts,
				Writable: false,
				Emit:     prop.EmitConst,
			},
			"TdpLimitMax": {
				Value:    tdp.MaxWatts,
				Writable: false,
				Emit:     prop.EmitConst,
			},
		},
	}

	props, err := prop.Export(conn, dbus.ObjectPath(ObjectPath), propSpec)
	if err != nil {
		return nil, fmt.Errorf("exporting properties: %w", err)
	}
	s.prop = props

	// Introspection so `busctl introspect` and steamos-manager can discover us.
	if err := conn.Export(introspectable(), dbus.ObjectPath(ObjectPath),
		"org.freedesktop.DBus.Introspectable"); err != nil {
		return nil, fmt.Errorf("exporting introspection: %w", err)
	}

	// Claim the name last, so we are fully functional before anyone can call in.
	reply, err := conn.RequestName(BusName, dbus.NameFlagDoNotQueue)
	if err != nil {
		return nil, fmt.Errorf("requesting bus name: %w", err)
	}
	if reply != dbus.RequestNameReplyPrimaryOwner {
		return nil, fmt.Errorf("bus name %s already taken — is another instance running?", BusName)
	}

	slog.Info("exported on system bus", "name", BusName, "path", ObjectPath)
	return s, nil
}

// onSetTdpLimit handles writes to the TdpLimit property.
//
// It validates and queues, and must never block. Steam emits bursts of Sets
// while the slider moves — five for a single value inside 10 ms was observed on
// this machine — and applying each one inline is what made changing TDP during
// a game able to freeze the system: every SMU command races amdgpu for the same
// mailbox. The committer coalesces the burst into one commit.
//
// Blocking here would be doubly wrong: godbus holds its properties lock across
// this callback, so a slow SMU write would stall every Get and GetAll on the
// object, including the Peer liveness check steamos-manager relies on.
//
// Returning nil is also what makes godbus store the new value and emit
// PropertiesChanged, which gives the optimistic update for free.
func (s *Service) onSetTdpLimit(c *prop.Change) *dbus.Error {
	watts, ok := c.Value.(uint32)
	if !ok {
		return dbus.MakeFailedError(fmt.Errorf("TdpLimit must be a uint32, got %T", c.Value))
	}
	if watts < tdp.MinWatts || watts > tdp.MaxWatts {
		return prop.ErrInvalidArg
	}

	s.com.Request(watts)
	s.announced.Store(watts)
	return nil
}

// onCommitted runs after the committer has tried to put a value on the
// hardware. Success needs nothing: godbus announced the value when the Set
// callback returned.
//
// Failure is reported by correcting the property, which is the idiomatic
// D-Bus way to say "your request did not stick" and which Steam already
// listens for. A D-Bus error reply is not available here — the method call was
// answered long ago — and would reach nobody anyway; Steam's slider surfaces
// none.
func (s *Service) onCommitted(watts uint32, err error) {
	if err == nil {
		return
	}
	// Read the cache, not the hardware: Current() is itself an SMU mailbox
	// command, and issuing one to explain that a mailbox command just failed is
	// how a failure becomes a wedge.
	actual := s.ctl.LastApplied()
	if actual == 0 {
		// Nothing has ever committed, so there is no honest value to report.
		slog.Warn("TDP limit not applied and no known-good value to fall back to",
			"requested", watts)
		return
	}
	s.syncTo(actual)
}

// syncTo republishes TdpLimit without re-entering the write path.
//
// It must be SetMust, not Set: prop.Properties.Set is the D-Bus-facing setter
// and invokes the registered Callback, so it would re-enter onSetTdpLimit and
// queue a spurious commit — and, before this change, deadlock outright against
// the lock the caller was already holding.
func (s *Service) syncTo(watts uint32) {
	if watts == 0 || watts == s.announced.Load() {
		return // nothing new to say
	}
	s.prop.SetMust(Interface, "TdpLimit", watts)
	s.announced.Store(watts)
	slog.Info("corrected exported TdpLimit", "watts", watts)
}

// Conn exposes the system bus connection so other components (the resume
// watcher) can reuse it instead of opening a second one.
func (s *Service) Conn() *dbus.Conn { return s.conn }

// Controller returns the underlying controller.
func (s *Service) Controller() *tdp.Controller { return s.ctl }

type introspectableNode string

func (i introspectableNode) Introspect() (string, *dbus.Error) {
	return string(i), nil
}

func introspectable() interface{} {
	return introspectableNode(`<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect">
      <arg name="out" direction="out" type="s"/>
    </method>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg name="interface" direction="in" type="s"/>
      <arg name="property" direction="in" type="s"/>
      <arg name="value" direction="out" type="v"/>
    </method>
    <method name="GetAll">
      <arg name="interface" direction="in" type="s"/>
      <arg name="props" direction="out" type="a{sv}"/>
    </method>
    <method name="Set">
      <arg name="interface" direction="in" type="s"/>
      <arg name="property" direction="in" type="s"/>
      <arg name="value" direction="in" type="v"/>
    </method>
    <signal name="PropertiesChanged">
      <arg name="interface" type="s"/>
      <arg name="changed_properties" type="a{sv}"/>
      <arg name="invalidated_properties" type="as"/>
    </signal>
  </interface>
  <interface name="com.steampowered.SteamOSManager1.TdpLimit1">
    <property name="TdpLimit" type="u" access="readwrite"/>
    <property name="TdpLimitMin" type="u" access="read">
      <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="const"/>
    </property>
    <property name="TdpLimitMax" type="u" access="read">
      <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="const"/>
    </property>
  </interface>
</node>`)
}
