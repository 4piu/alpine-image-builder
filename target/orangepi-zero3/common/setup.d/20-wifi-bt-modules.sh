#!/bin/sh
# Onboard AW859A wifi/BT (common/kernel.config, common/patches/) isn't
# tied to any hotplug bus -- it's a platform devicetree node, not a USB
# device with its own udev-triggered modalias autoload -- so nothing
# loads sprdwl_ng/sprdbt_tty at boot without this. modprobe resolves
# uwe5622_bsp_sdio (the shared platform/SDIO glue both depend on)
# automatically, so only the two leaf modules need listing.
echo sprdwl_ng >> /etc/modules
echo sprdbt_tty >> /etc/modules
rc-update add modules boot
