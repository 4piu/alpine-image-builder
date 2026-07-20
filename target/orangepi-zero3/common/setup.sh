#!/bin/sh
# One-time post-expansion hook for this target -- see target/README.md.
# Baked into the image and run exactly once, after first-boot rootfs
# expansion has fully completed (not on every boot, not mid-expansion).
# Empty (or missing entirely) has no effect.
#
# Runs as root, via `sh`, after expand-rootfs.sh's completion marker
# shows up. A non-zero exit leaves the hook installed to retry next boot.
#
# Add commands like:
#   apk add --no-cache htop
#   rc-update add some-service default

# Disable kernel messages on the console
cat > /etc/profile.d/00suppress_kmsg.sh << 'EOF'
if [ "$(tty)" = "/dev/ttyS0" ] && [ $(cat /proc/sys/kernel/printk | awk '{print $1}') -gt 1 ]; then
    echo "Suppressing low-priority kernel messages on serial console."
    dmesg -n 1
fi
EOF

# Onboard AW859A wifi/BT (common/kernel.config, common/patches/) isn't
# tied to any hotplug bus -- it's a platform devicetree node, not a USB
# device with its own udev-triggered modalias autoload -- so nothing
# loads sprdwl_ng/sprdbt_tty at boot without this. modprobe resolves
# uwe5622_bsp_sdio (the shared platform/SDIO glue both depend on)
# automatically, so only the two leaf modules need listing.
echo sprdwl_ng >> /etc/modules
echo sprdbt_tty >> /etc/modules
rc-update add modules boot

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