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
	"time"

	"github.com/coreos/go-systemd/v22/daemon"

	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/config"
	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/dbusiface"
	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/smu"
	"github.com/dahui/onexplayer-x2-mini-pro-cachyos/tdpd/internal/tdp"
)

// fallbackStateDir is used when systemd does not supply STATE_DIRECTORY, i.e.
// when running the binary by hand.
const fallbackStateDir = "/var/lib/oxp-tdpd"

// version is stamped by the release build via -ldflags "-X main.version=<tag>".
// It must stay a package-level var in main: -X silently does nothing if the
// symbol does not exist, so a missing declaration is not a build error, just a
// binary that cannot say what it is. Releases up to v0.1.1 passed that flag with
// no such variable here and were stamped with nothing at all.
var version = "dev"

func main() {
	var (
		verbose   = flag.Bool("v", false, "verbose logging")
		showVer   = flag.Bool("version", false, "print the version and exit")
		status    = flag.Bool("status", false, "print current SMU limits and exit")
		set       = flag.Uint("set", 0, "apply a TDP limit in watts and exit")
		cfgPath   = flag.String("config", config.DefaultPath, "path to the config file")
		recapture = flag.Bool("recapture-defaults", false,
			"re-read the firmware's fast/slow limits and store them as the defaults. "+
				"Only correct when the current limits really are the firmware's, i.e. "+
				"right after a reboot with the daemon stopped.")
	)
	flag.Parse()

	if *showVer {
		fmt.Println("oxp-tdpd", version)
		return
	}

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
		// Forced: a fresh process has no cache describing the hardware, so
		// there is nothing to safely skip. Note this path does not coordinate
		// with a running daemon — smu's mutex is process-local. An advisory
		// lock on the driver directory would fix that; it always raced, and
		// this change neither improves nor worsens it.
		return ctl.ApplyForce(set)
	}

	// Coalesce the stream of Sets Steam emits while its slider moves. Applying
	// each one inline is what let a TDP change during a game freeze the system.
	com := tdp.NewCommitter(ctl)

	svc, err := dbusiface.Export(ctl, com)
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

	if _, err := daemon.SdNotify(false, daemon.SdNotifyStopping); err != nil {
		slog.Debug("sd_notify stopping failed", "err", err)
	}

	// Flush a value the user chose but that has not settled yet — Steam is
	// already showing it, so dropping it leaves that display wrong. This is not
	// the same as restoring limits on exit, which we still deliberately do not
	// do (see below).
	//
	// The timeout bounds how long we wait, not how long the write takes: a
	// goroutine stuck in an uninterruptible write() to the ryzen_smu mailbox
	// cannot be cancelled from Go, and process exit will still wait on it.
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopCancel()
	if err := com.Close(stopCtx); err != nil {
		slog.Warn("could not flush the pending TDP limit before exit", "err", err)
	}

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
