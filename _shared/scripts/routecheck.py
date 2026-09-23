#!/usr/bin/env python3
"""routecheck.py — the route gate for bench.bat (and any native-Windows
probe of a published WSL2 port).

A plain TCP connect cannot tell the three live states on this box apart
enough: the WSL2 relay (wslrelay.exe on the Windows side) keeps a slot
per forwarded port, and a slot left over from a REMOVED container accepts
TCP and then forwards into a VM that has no listener — the client hangs
for its whole read timeout (the 09-04 300 s blackhole was exactly this,
on 8115, after the flash-next container was removed in the 27B switch;
the wslrelay.exe slot was verified holding the port the same day). So
this gate makes an actual HTTP request the tier must answer:

  exit 0  127.0.0.1:<port>/v1/models answered 2xx - the tier is up
  exit 2  connection refused - the port is not published; the tier is
          down (start it with start-mtp.bat first)
  exit 3  the port listens but never answers within the deadline - a
          dead relay slot (or a half-dead tier). The clear for a dead
          slot is 'wsl --shutdown' in a terminal: a fresh VM rewrites
          the relay table. The model tier is down for the window that
          clears it anyway.

Usage:  python routecheck.py [port]     (default 8115)
"""
import sys
import urllib.error
import urllib.request

DEADLINE_S = 8


def _dead_message(port):
    return ("routecheck: 127.0.0.1:%s accepted but gave no answer within "
            "%d s - a listener is holding the port dead (a WSL relay "
            "slot outlived its container; 'wsl --shutdown' in a "
            "terminal clears it)" % (port, DEADLINE_S))


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "8115"
    url = "http://127.0.0.1:" + port + "/v1/models"
    try:
        with urllib.request.urlopen(url, timeout=DEADLINE_S) as r:
            if not 200 <= r.status < 300:
                print("routecheck: HTTP %d from %s - not a vLLM API"
                      % (r.status, url))
                return 3
        print("routecheck: %s answered - the tier is up" % url)
        return 0
    except urllib.error.URLError as e:
        cause = getattr(e, "reason", e)
        if (isinstance(cause, ConnectionRefusedError)
                or getattr(cause, "errno", None) in (111, 10061)):
            print("routecheck: connection refused on 127.0.0.1:%s - "
                  "the tier is down" % port)
            return 2
        print(_dead_message(port))
        return 3
    except TimeoutError:
        # newer pythons surface the read timeout unwrapped
        print(_dead_message(port))
        return 3
    except Exception as e:
        print("routecheck: %s on %s" % (repr(e), url))
        return 3


if __name__ == "__main__":
    sys.exit(main())
