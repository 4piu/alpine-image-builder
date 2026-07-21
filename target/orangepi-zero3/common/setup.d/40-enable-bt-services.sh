#!/bin/sh
# bluez/bluez-openrc/dbus (packages.txt) being installed doesn't start
# anything by itself -- confirmed on real hardware: without this,
# bluetoothd never runs, so bluetoothctl fails immediately with a D-Bus
# connection assertion ("Waiting to connect to bluetoothd..." then
# aborts) since there's no system bus for it to reach. OpenRC's own
# dependency resolution (bluetooth's init script already needs dbus)
# handles start order once both are actually in a runlevel -- that's
# the one missing step here, not a manual ordering problem.
rc-update add dbus default
rc-update add bluetooth default
