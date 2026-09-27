#!/bin/sh
# Run trndi-cli on a made-up day, for screenshots: doc/demo.sh --stats
#
# Uses the `make demo` build and Trndi's list debug backend (API_D_LIST), which
# replays the readings typed as its user name at five-minute spacing, against
# fixed limits of 60/90/140/160 mg/dL, so every band shows up. The day has
# three meals, a night-time dip and one 40-minute hole, and ends at the moment
# the script runs.
#
# Everything the run touches lives in a temporary directory: the settings, and
# the debug log that a DEBUG build otherwise truncates in the GUI's own place
# (~/Library/Application Support/com.slicke.trndi on macOS, the working
# directory elsewhere).
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
bin="$root/bin/demo/trndi-cli"
[ -x "$bin" ] || make -C "$root" demo >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 288 readings, oldest first, in mg/dL; '_' leaves a slot empty. The C locale
# because BSD awk reads "18.5" as 18 under a decimal-comma LANG.
series=$(LC_ALL=C awk -v h0="$(date +%H)" -v m0="$(date +%M)" 'BEGIN {
  now = h0 + m0 / 60
  for (i = 0; i < 288; i++) {
    h = now - (287 - i) * 5 / 60
    h -= 24 * int(h / 24); if (h < 0) h += 24
    v = 112 + 8 * sin(i / 7)
    split("8.0 12.5 18.5", peak, " "); split("70 60 85", amp, " ")
    split("1.3 1.2 1.5", w, " ")
    for (k = 1; k <= 3; k++) {            # meals
      d = h - peak[k]; if (d < 0) d += 24
      if (d < 4) v += amp[k] * (d / w[k]) * exp(1 - d / w[k])
    }
    d = h - 3.3; if (d < 0) d += 24       # night dip
    if (d < 2) v -= 58 * sin(3.14159265 * d / 2)
    out = (i >= 200 && i < 208) ? "_" : sprintf("%d", v + 0.5)
    printf "%s%s", (i ? " " : ""), out
  }
}')

mkdir -p "$tmp/cfg" "$tmp/home"
printf '[trndi]\nremote.type=API_D_LIST\nremote.target=%s\n' "$series" \
  > "$tmp/cfg/Trndi.cfg"

cd "$tmp/home"
XDG_CONFIG_HOME="$tmp/cfg" CFFIXED_USER_HOME="$tmp/home" "$bin" "$@"
