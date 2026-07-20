#!/bin/sh
# The BT side additionally needs its HCI UART line discipline attached
# every boot -- sprdbt_tty.ko only creates the /dev/ttyBT0 tty node,
# it doesn't register a hci0 itself (this chip isn't a self-registering
# USB device like btusb handles automatically). Real hardware testing
# found the working incantation: -P h4 (not "any" -- btattach, unlike
# the deprecated hciattach, rejects that name outright with "Invalid
# protocol"); rfkill starts this controller soft-blocked by default,
# hence the unblock. Desktop environments/BlueZ's bluetoothd don't do
# this step themselves -- it's genuinely board-specific glue, the same
# reason Raspberry Pi OS ships a dedicated pi-bluetooth package for its
# own onboard UART-attached chip.
cat > /etc/init.d/uwe5622-bt-attach << 'EOF'
#!/sbin/openrc-run

name="uwe5622-bt-attach"
description="Attach the onboard AW859A/uwe5622 Bluetooth controller"
command="/usr/bin/btattach"
command_args="-B /dev/ttyBT0 -P h4 -S 115200"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
	need modules
	after modules
	before bluetooth
}

start_pre() {
	rfkill unblock bluetooth
}
EOF
chmod +x /etc/init.d/uwe5622-bt-attach
rc-update add uwe5622-bt-attach default
