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
	"sync"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/prop"

	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/tdp"
)

const (
	BusName    = "io.aletheia.OxpTdp1"
	ObjectPath = "/io/aletheia/OxpTdp1"
	Interface  = "com.steampowered.SteamOSManager1.TdpLimit1"
)

// Service owns the D-Bus surface and serialises access to the controller.
type Service struct {
	mu   sync.Mutex
	ctl  *tdp.Controller
	conn *dbus.Conn
	prop *prop.Properties
}

// Export claims the bus name and publishes the interface.
func Export(ctl *tdp.Controller) (*Service, error) {
	conn, err := dbus.SystemBus()
	if err != nil {
		return nil, fmt.Errorf("connecting to system bus: %w", err)
	}

	s := &Service{ctl: ctl, conn: conn}

	propSpec := map[string]map[string]*prop.Prop{
		Interface: {
			"TdpLimit": {
				Value:    ctl.Current(),
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
func (s *Service) onSetTdpLimit(c *prop.Change) *dbus.Error {
	watts, ok := c.Value.(uint32)
	if !ok {
		return dbus.MakeFailedError(fmt.Errorf("TdpLimit must be a uint32, got %T", c.Value))
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if watts < tdp.MinWatts || watts > tdp.MaxWatts {
		return prop.ErrInvalidArg
	}
	if err := s.ctl.Apply(watts); err != nil {
		slog.Error("failed to apply TDP limit", "watts", watts, "err", err)
		return dbus.MakeFailedError(err)
	}
	return nil
}

// Sync refreshes the exported TdpLimit from hardware. Called after resume so
// clients see the real value rather than a stale one.
func (s *Service) Sync() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.prop.Set(Interface, "TdpLimit", dbus.MakeVariant(s.ctl.Current())); err != nil {
		slog.Warn("failed to sync TdpLimit property", "err", err)
	}
}

// Conn exposes the system bus connection so other components (the resume
// watcher) can reuse it instead of opening a second one.
func (s *Service) Conn() *dbus.Conn { return s.conn }

// Controller returns the underlying controller.
func (s *Service) Controller() *tdp.Controller { return s.ctl }

// Lock/Unlock let callers serialise a reapply against in-flight D-Bus writes.
func (s *Service) Lock()   { s.mu.Lock() }
func (s *Service) Unlock() { s.mu.Unlock() }

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
