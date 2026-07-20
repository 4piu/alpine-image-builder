#!/bin/sh
# Disable low-priority kernel messages on the serial console -- see
# target/README.md's setup.d/*.sh section for how/when this runs.
cat > /etc/profile.d/00suppress_kmsg.sh << 'EOF'
if [ "$(tty)" = "/dev/ttyS0" ] && [ $(cat /proc/sys/kernel/printk | awk '{print $1}') -gt 1 ]; then
    echo "Suppressing low-priority kernel messages on serial console."
    dmesg -n 1
fi
EOF
