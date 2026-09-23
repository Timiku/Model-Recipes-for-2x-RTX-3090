#!/usr/bin/env python3
# arm-probe.py -- the WSL2 device re-arm probe (local; not source-derived).
#
# Why: the WSL2 nvidia driver re-arms each card's device state when the
# last CUDA user on it exits (a tier's stop). A boot that starts inside
# that re-arm window can create a CUDA context fine and still die on its
# first real allocation: "CUDA driver error: device not ready" (the 09-03
# flash-next boot died exactly there: rank 1's first layer build, minutes
# after the 27B tier left the cards).
#
# What this does: the image bakes it at /usr/local/bin/arm-probe.py; the
# start bat runs it in a throwaway container on the pinned pair BEFORE
# the boot (and before it arms the watchdog): it creates a context on
# each card and allocates a handful of bytes. The act of arming IS the
# fix - by the time the real engine initializes seconds later, the device
# state is warm. The script retries on its own (3 attempts, 3 s apart);
# exit 0 = both cards armed, 1 = still not (the bat stops, says wait,
# re-run).
#
# The card pair arrives as CUDA_VISIBLE_DEVICES (the bat's literal pin,
# the yml's DEVICE_PAIR); the probe indexes whatever it sees, so it
# cannot drift from the boot.
import sys
import time

import torch


def main() -> int:
    cards = list(range(torch.cuda.device_count()))
    if not cards:
        print("  arm-probe: no visible CUDA device - the pin or the WSL "
              "GPU stack is wrong")
        return 1
    for attempt in range(3):
        ok = True
        for i in cards:
            try:
                torch.cuda.set_device(i)
                _ = torch.zeros(16, device="cuda:%d" % i)
                torch.cuda.synchronize(i)
                print("  arm-probe: card %d: context + allocation OK" % i)
            except Exception as e:
                ok = False
                print("  arm-probe: card %d: not ready (%s: %s)"
                      % (i, type(e).__name__, e))
        if ok:
            return 0
        print("  arm-probe: attempt %d/3 failed; the driver is still "
              "recovering - waiting 3 s" % (attempt + 1))
        time.sleep(3)
    print("  arm-probe: the cards did not arm within 3 attempts")
    return 1


if __name__ == "__main__":
    sys.exit(main())
