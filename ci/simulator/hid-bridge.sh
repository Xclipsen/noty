#!/bin/bash
# Host side of `KeyboardSmokeTests.hid`: every *.key file in $1 holds one HID
# usage. Presses it on simulator $2 through AXe, then removes the file, which
# tells the test that the key is done.
dir=$1 udid=$2
while true; do
  for file in "$dir"/*.key; do
    [ -e "$file" ] || continue
    usage=$(cat "$file")
    echo "$(date +%T) key $usage" >> "$dir/bridge.log"
    axe key "$usage" --udid "$udid" >> "$dir/bridge.log" 2>&1
    rm -f "$file"
  done
  sleep 0.1
done
