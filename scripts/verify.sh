#!/usr/bin/env bash

set -u

echo "Kernel command line"
cat /proc/cmdline

echo
echo "AMD graphics"
lspci -nnk | grep -A4 -i 'vga\|display'

echo
echo "Hyprland monitor"
hyprctl monitors all

echo
echo "Hyprland configuration errors"
hyprctl configerrors

echo
echo "Thunderbolt devices"
boltctl list

echo
echo "Network devices"
nmcli device status

echo
echo "IPv4 routes"
ip -4 route

echo
echo "Aquantia/OWC Ethernet"
lspci -nnk | grep -A4 -i 'ethernet\|aquantia'

