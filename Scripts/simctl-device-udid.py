#!/usr/bin/env python3
"""Print the UDID of the simulator with the given name and runtime version.

Reads `xcrun simctl list devices --json` on stdin. Used by capture-screenshots.sh, which needs to point
`simctl io <udid> screenshot` at one specific device: `booted` is ambiguous whenever a second simulator is running,
and the deliverables must come from the device the App Store sizes are cut for.

    xcrun simctl list devices --json | simctl-device-udid.py 'iPhone 17 Pro Max' 26.5

Exits non-zero with a message on stderr when no such device exists, so the caller fails loudly rather than
capturing from whatever else happens to be booted.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <device name> <os version>", file=sys.stderr)
        return 2
    name, os_version = sys.argv[1], sys.argv[2]

    devices = json.load(sys.stdin)["devices"]
    # Runtime identifiers look like "com.apple.CoreSimulator.SimRuntime.iOS-26-5".
    wanted_suffix = "iOS-" + os_version.replace(".", "-")
    for runtime, entries in devices.items():
        if not runtime.endswith(wanted_suffix):
            continue
        for device in entries:
            if device.get("name") == name and device.get("isAvailable", True):
                print(device["udid"])
                return 0

    print(f"no available simulator named {name!r} on iOS {os_version}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
