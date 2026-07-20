#!/bin/sh
# Enable the Realtek 8821CU USB WiFi adapter
echo rtw88_8821cu >> /etc/modules
rc-update add modules boot
