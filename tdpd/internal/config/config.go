// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>

// Package config reads oxp-tdpd's small settings file.
//
// The format is a TOML-compatible subset — `key = "value"` with `#` comments —
// parsed by hand rather than pulling in a TOML module for three keys. A real
// TOML file will parse correctly here, so migrating later costs nothing.
package config

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// DefaultPath is where the installer puts the config.
const DefaultPath = "/etc/oxp-tdpd.conf"

// Policy decides which power limits a single slider value drives.
type Policy string

const (
	// PolicyAll writes STAPM, fast and slow all to the slider value. The
	// slider becomes a real ceiling. Default.
	PolicyAll Policy = "all"

	// PolicyStapm writes only the sustained limit and restores fast/slow to
	// the firmware defaults captured at first run, preserving stock burst
	// behaviour. Measured consequence on this device: a 45 W setting still ran
	// 72-79 W at 95 C, because STAPM's time constant is minutes-scale.
	PolicyStapm Policy = "stapm"

	// PolicyHeadroom writes STAPM and slow at the slider with fast 25% above
	// (clamped to the range maximum): bounded sustained power, some burst.
	PolicyHeadroom Policy = "headroom"
)

// Config is the daemon's tunable state.
type Config struct {
	Policy Policy
}

// Default returns the built-in configuration.
func Default() Config {
	return Config{Policy: PolicyAll}
}

// Load reads path. A missing file is not an error — the defaults apply.
func Load(path string) (Config, error) {
	cfg := Default()

	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return cfg, fmt.Errorf("opening %s: %w", path, err)
	}
	defer f.Close()

	scan := bufio.NewScanner(f)
	for line := 1; scan.Scan(); line++ {
		text := strings.TrimSpace(scan.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		key, value, ok := strings.Cut(text, "=")
		if !ok {
			return cfg, fmt.Errorf("%s:%d: expected key = value", path, line)
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)

		switch key {
		case "policy":
			p := Policy(value)
			switch p {
			case PolicyAll, PolicyStapm, PolicyHeadroom:
				cfg.Policy = p
			default:
				return cfg, fmt.Errorf("%s:%d: unknown policy %q (want all, stapm or headroom)",
					path, line, value)
			}
		default:
			return cfg, fmt.Errorf("%s:%d: unknown key %q", path, line, key)
		}
	}
	if err := scan.Err(); err != nil {
		return cfg, fmt.Errorf("reading %s: %w", path, err)
	}
	return cfg, nil
}
