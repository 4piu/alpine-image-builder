#!/bin/bash

tool_dir=$(dirname "$1")
apk=$(which apk)

mkdir -p "$tool_dir"

if [ -z "$apk" ]; then # get apk-tools-static
    set -e

    echo "##############################"
    echo "# You do not have apk, so we #"
    echo "# will get a static copy and #"
    echo "# and use it                 #"
    echo "##############################"
    arch=$(uname -m) # armv6l> armhf aarch64 armv7
    case $arch in
        armv6*|armhf) arch="armhf";;
        x86_64|x86|aarch64) arch="$arch";;
        armv7*) arch="armv7";;
        *) echo "unknown native arch '$arch'"
        exit 1
    esac
    base_url="$ROOTFS_URL/main/$arch"
    wget -O "$tool_dir/index.html" "$base_url"
    pkg=$(grep apk-tools-static "$tool_dir/index.html" |sed 's!.*apk-!apk-!;s!<.*!!')
    wget -O "$tool_dir/apk-tools-static.apk" "$base_url/$pkg"
    tar -xf "$tool_dir/apk-tools-static.apk" -C "$tool_dir" sbin/apk.static --strip-components=1
    mv "$tool_dir/apk.static" "$tool_dir/apk"

else
    echo "##############################"
    echo "# You have apk, so we will   #"
    echo "# use the system apk         #"
    echo "##############################"
    ln -sf "$apk" "$tool_dir/apk"
fi
