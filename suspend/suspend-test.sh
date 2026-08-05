#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Walk the suspend sequence one stage at a time, leaving evidence on disk at
# every step so a hard hang still tells us where it died.
#
# Background: this machine has never suspended successfully -- zero
# `PM: suspend entry` across every recorded boot -- and a single
# `rtcwake -m mem -s 15` locked it hard enough to need a forced power-off, with
# nothing written to the journal. So the goal here is not "make it sleep", it is
# "find the stage that hangs, without losing the machine".
#
# /sys/power/pm_test is the tool for that: at every level except `none` the
# kernel runs the suspend sequence down to that point, waits 5s, and comes back
# up WITHOUT entering the low-power state. A driver that hangs on the way down
# is caught with the machine still recoverable.
#
# Ladder, shallowest first:
#   freezer    freeze userspace only            (safe even over SSH)
#   devices    + suspend all device drivers     <-- the interesting one
#   platform   + platform/ACPI callbacks
#   core       + syscore ops
#   none       REAL suspend, actually enters s0ix
#
# Usage, at the PHYSICAL CONSOLE:
#   sudo ./suspend-test.sh baseline    # unload ryzen_smu + oxpec, then ladder
#   sudo ./suspend-test.sh ladder      # ladder with whatever is loaded now
#   sudo ./suspend-test.sh freezer     # one named stage
#
set -uo pipefail

LOG=/var/log/suspend-test.log
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- log that survives a hang -----------------------------------------------
# Every record is followed by sync(). Without this a hard hang loses the very
# line that says what we were attempting, which is exactly what happened the
# first time.
record() {
	printf '%s | %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
	sync
}

if [[ $EUID -ne 0 ]]; then
	echo "must run as root (sudo $0 $*)" >&2
	exit 1
fi

# --- refuse to run anywhere but the physical console -------------------------
# This is the whole reason the first attempt cost two forced reboots: the
# session died with the machine and there was no way to see or recover
# anything.
#
# Do NOT test $SSH_CONNECTION / $SSH_TTY here. sudo resets the environment, so
# both are empty by the time this runs and the guard silently passes -- which is
# exactly how an early version of this script ran a `devices` suspend over SSH.
# Detect the session instead, by walking the process tree for sshd and by
# requiring a real virtual terminal.

is_remote_session() {
	local pid=$PPID depth=0 comm
	while [[ "$pid" -gt 1 && "$depth" -lt 25 ]]; do
		comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
		case "$comm" in
			sshd|sshd-session|mosh-server) return 0 ;;
		esac
		pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || return 1
		depth=$((depth + 1))
	done
	return 1
}

# A physical VT is /dev/tty1..N. Anything else (/dev/pts/N, no tty) is a
# pseudo-terminal: SSH, a terminal emulator, or a service.
at_physical_console() {
	local t
	t=$(tty 2>/dev/null) || return 1
	[[ "$t" =~ ^/dev/tty[0-9]+$ ]]
}

if [[ "${CONSOLE_OVERRIDE:-0}" != "1" ]]; then
	unsafe=""
	is_remote_session      && unsafe="an SSH session"
	at_physical_console    || unsafe="${unsafe:-not a physical virtual terminal ($(tty 2>/dev/null || echo 'no tty'))}"

	if [[ -n "$unsafe" ]]; then
		cat >&2 <<-EOF

		REFUSING TO RUN: $unsafe.

		A suspend hang takes the network and the session with it, so you
		would lose both the machine and any way to observe what happened.

		Run this from a real virtual terminal on the handheld itself:
		switch with Ctrl-Alt-F3, log in, and run it there.

		The 'freezer' stage is the one exception -- it freezes userspace
		and returns without touching any driver, so it is safe anywhere:

		    sudo CONSOLE_OVERRIDE=1 $0 freezer

		Using CONSOLE_OVERRIDE=1 for any deeper stage risks the machine.

		EOF
		exit 1
	fi
fi

# --- make a hang leave visible evidence -------------------------------------
prepare() {
	say "Preparing evidence capture"

	# Keep console output flowing through the transition. Without this the
	# console is suspended early and the screen tells you nothing.
	if echo N > /sys/module/printk/parameters/console_suspend 2>/dev/null; then
		note "console_suspend=N (console stays live through the transition)"
	else
		note "WARNING: could not disable console_suspend"
	fi

	# Verbose PM messages naming each device as it suspends -- this is what
	# identifies the offending driver.
	if echo 1 > /sys/power/pm_debug_messages 2>/dev/null; then
		note "pm_debug_messages=1 (per-device suspend logging)"
	else
		note "WARNING: could not enable pm_debug_messages"
	fi

	echo 8 > /proc/sys/kernel/printk 2>/dev/null && note "printk level 8"

	note "log: $LOG"
	record "=== session start: kernel $(uname -r), modules: $(lsmod | grep -cE '^(ryzen_smu|oxpec) ') oot loaded ==="
}

modstate() {
	local r o
	r=$(lsmod | grep -c '^ryzen_smu ' || true)
	o=$(lsmod | grep -c '^oxpec ' || true)
	echo "ryzen_smu=$r oxpec=$o"
}

# --- run one pm_test stage --------------------------------------------------
attempt() {
	local level="$1"

	if ! grep -qw "$level" /sys/power/pm_test 2>/dev/null; then
		note "stage '$level' not supported by this kernel, skipping"
		return 0
	fi

	echo "$level" > /sys/power/pm_test || {
		note "could not select pm_test=$level"
		return 1
	}

	say "Stage: $level   [$(modstate)]"
	if [[ "$level" == "none" ]]; then
		note "*** THIS IS A REAL SUSPEND -- the machine will actually sleep ***"
		if [[ "${AUTO:-0}" == "1" ]]; then
			note "unattended: arming an RTC alarm to wake after ${WAKE_SECS:-30}s"
		else
			note "Wake it with the power button. If it does not wake, force power off."
		fi
	else
		note "Runs the sequence to this point, waits 5s, returns automatically."
	fi

	if [[ "${AUTO:-0}" != "1" ]]; then
		read -rp "    Enter to attempt, or Ctrl-C to stop: " _
	fi

	# Record BEFORE attempting -- if the machine dies here, this line is the
	# evidence. Flush the journal too, so the kernel's own messages up to this
	# point survive a hard hang.
	record "ATTEMPT pm_test=$level $(modstate)"
	journalctl --sync 2>/dev/null || true

	local start=$SECONDS rc=0
	if [[ "$level" == "none" && "${AUTO:-0}" == "1" ]]; then
		# Real suspend, unattended: the RTC alarm is the only way back.
		rtcwake -m mem -s "${WAKE_SECS:-30}"
		rc=$?
	else
		echo mem > /sys/power/state
		rc=$?
	fi
	local elapsed=$((SECONDS - start))

	record "SURVIVED pm_test=$level rc=$rc elapsed=${elapsed}s"
	say "Returned from '$level' after ${elapsed}s (rc=$rc)"

	# Reset so a later reboot does not leave a test mode armed.
	echo none > /sys/power/pm_test 2>/dev/null
	return 0
}

ladder() {
	for level in freezer devices platform core; do
		attempt "$level" || return 1
	done

	say "All pm_test stages survived"
	record "ladder complete, all stages survived $(modstate)"

	if [[ "${AUTO:-0}" == "1" && "${THEN_REAL:-0}" == "1" ]]; then
		note "proceeding to a real suspend (unattended, RTC wake)"
		attempt none
	else
		note "The suspend path itself is sound to the syscore stage."
		note "Run 'sudo $0 none' for a real suspend when you are ready."
	fi
}

# --- baseline: what does this hardware do with nothing of ours loaded? ------
baseline() {
	say "Unloading out-of-tree modules for a clean baseline"
	note "This is the missing data point: whether suspend EVER works here."

	systemctl stop oxp-tdpd 2>/dev/null && note "stopped oxp-tdpd (holds ryzen_smu)"
	modprobe -r ryzen_smu 2>/dev/null && note "unloaded ryzen_smu" || note "ryzen_smu not loaded"
	modprobe -r oxpec     2>/dev/null && note "unloaded oxpec"     || note "oxpec not loaded"

	record "baseline: $(modstate)"
	ladder

	say "Restore afterwards with"
	note "sudo modprobe ryzen_smu && sudo modprobe oxpec && sudo systemctl start oxp-tdpd"
}

case "${1:-ladder}" in
	baseline)                    prepare; baseline ;;
	ladder)                      prepare; ladder ;;
	freezer|devices|platform|core|none)
	                             prepare; attempt "$1" ;;
	*)
		echo "usage: $0 {baseline|ladder|freezer|devices|platform|core|none}" >&2
		exit 1
		;;
esac
