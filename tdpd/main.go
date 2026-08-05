// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

// oxp-tdpd exposes TDP control for the ONEXPLAYER X2Mini PRO to Steam.
//
// steamos-manager supports two local TDP methods and neither works on this
// device: amdgpu_hwmon needs power1_cap (absent on Strix Halo) and
// firmware_attribute needs a vendor platform driver (OneXPlayer ships none).
// It can, however, proxy its TdpLimit1 interface to an external daemon
// registered in /etc/steamos-manager/remotes.d/ — which is what this is.
//
// Limits are applied over the SMU MP1 mailbox via the ryzen_smu kernel module.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/coreos/go-systemd/v22/daemon"

	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/config"
	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/dbusiface"
	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/smu"
	"github.com/dahui/onexplayer-x2-mini/tdpd/internal/tdp"
)

// fallbackStateDir is used when systemd does not supply STATE_DIRECTORY, i.e.
// when running the binary by hand.
const fallbackStateDir = "/var/lib/oxp-tdpd"

func main() {
	var (
		verbose   = flag.Bool("v", false, "verbose logging")
		status    = flag.Bool("status", false, "print current SMU limits and exit")
		set       = flag.Uint("set", 0, "apply a TDP limit in watts and exit")
		cfgPath   = flag.String("config", config.DefaultPath, "path to the config file")
		recapture = flag.Bool("recapture-defaults", false,
			"re-read the firmware's fast/slow limits and store them as the defaults. "+
				"Only correct when the current limits really are the firmware's, i.e. "+
				"right after a reboot with the daemon stopped.")
	)
	flag.Parse()

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr,
		&slog.HandlerOptions{Level: level})))

	if err := run(*status, uint32(*set), *cfgPath, *recapture); err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}
}

func run(status bool, set uint32, cfgPath string, recapture bool) error {
	if status {
		return printStatus()
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		return err
	}

	stateDir := os.Getenv("STATE_DIRECTORY")
	if stateDir == "" {
		stateDir = fallbackStateDir
	}

	ctl, err := tdp.New(cfg.Policy, stateDir)
	if err != nil {
		return err
	}

	if recapture {
		if err := ctl.RecaptureDefaults(); err != nil {
			return err
		}
		fmt.Println("firmware defaults recaptured")
		return nil
	}

	if set != 0 {
		return ctl.Apply(set)
	}

	svc, err := dbusiface.Export(ctl)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go svc.WatchResume(ctx)

	if _, err := daemon.SdNotify(false, daemon.SdNotifyReady); err != nil {
		slog.Debug("sd_notify failed (not running under systemd?)", "err", err)
	}
	slog.Info("ready")

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	s := <-sigs
	slog.Info("shutting down", "signal", s.String())

	// Deliberately not restoring anything on exit. The firmware reapplies its
	// own limits at boot, and resetting here would override a limit the user
	// explicitly chose.
	return nil
}

func printStatus() error {
	if !smu.Available() {
		return fmt.Errorf("ryzen_smu not loaded (modprobe ryzen_smu)")
	}
	if !smu.PMTableAvailable() {
		return fmt.Errorf("PM table unavailable — ryzen_smu does not know this " +
			"firmware's table version; see ryzen-smu/ in this repo")
	}
	ver, err := smu.PMTableVersion()
	if err != nil {
		return err
	}
	l, err := smu.ReadLimits()
	if err != nil {
		return err
	}
	fmt.Printf("PM table version: 0x%X\n", ver)
	fmt.Printf("%-18s %8s %8s\n", "", "limit", "current")
	fmt.Printf("%-18s %7.1fW %7.1fW\n", "STAPM (sustained)", l.StapmLimit, l.StapmValue)
	fmt.Printf("%-18s %7.1fW %7.1fW\n", "PPT fast", l.FastLimit, l.FastValue)
	fmt.Printf("%-18s %7.1fW %7.1fW\n", "PPT slow", l.SlowLimit, l.SlowValue)
	return nil
}
