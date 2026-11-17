#!/bin/bash
# Identify the speaker amplifiers of a Snapdragon X laptop (written for the
# Samsung Galaxy Book4 Edge) by their SoundWire bus and address, without
# relying on how the device tree routes channels to amps.
#
# For each WSA883x/WSA884x amp it switches off the other amps' "<prefix> DAC
# Switch" and plays a test signal on every channel of the speaker sink, so
# only the amp under test can play, whatever the routing. The DAC Switch is
# a SoundWire port enable that the driver applies only when the stream is set
# up, so the sink is suspended while the switches change (pactl), and the
# stream starts afterwards; switching during playback has no effect.
#
# The signal: 1 s silence; 1.5 s with a different tone on each channel at
# once (1000, 1100, 1300, 1400 Hz on channels 1-4, to show which channel
# feeds the amp); 0.5 s silence; 3 s of 300 Hz (a woofer plays it clearly, a
# tweeter barely); 0.5 s silence; 3 s of 3 kHz (both play it).
#
# Usage, as the desktop user (not root), speaker volume at 80-100 %:
#   speaker-amp-id.sh            listen: you note which end of the base
#                                each amp plays from, and whether 300 Hz is
#                                clearly audible
#   speaker-amp-id.sh record     also records the default microphone and
#                                prints the channel and the 300 Hz / 3 kHz
#                                levels per amp
#   SINK=<node.name> speaker-amp-id.sh   if the speaker sink isn't found
#
# The amps' DAC switches are restored on exit.
set -eu
mode=${1:-listen}
command -v pactl >/dev/null || { echo "Needs pactl (libpulse) to suspend the sink." >&2; exit 1; }

# The amps: SoundWire devices of Qualcomm (0217) WSA883x (0202) / WSA884x (0204).
declare -a pre bus adr
for d in /sys/bus/soundwire/devices/sdw:*:0217:020[24]:*; do
    [ -e "$d/of_node" ] || continue
    node=$(readlink -f "$d/of_node")
    p=$(tr -d '\0' < "$node/sound-name-prefix" 2>/dev/null) || continue
    ctrl=${node%/*}; label=$ctrl
    for s in /sys/firmware/devicetree/base/__symbols__/swr*; do
        [ "/sys/firmware/devicetree/base$(tr -d '\0' < "$s")" = "$ctrl" ] && label=${s##*/}
    done
    pre+=("$p"); bus+=("$label"); adr+=("${d##*:}")
done
[ ${#pre[@]} -gt 0 ] || { echo "No WSA883x/WSA884x amps with a sound-name-prefix found." >&2; exit 1; }

# The card that has their controls. Use hw:N: the UCM remap on the default
# control device hides the individual amp controls.
card=
for c in /proc/asound/card[0-9]*; do
    n=${c##*card}
    amixer -D hw:$n cget name="${pre[0]} DAC Switch" >/dev/null 2>&1 && { card=$n; break; }
done
[ -n "$card" ] || { echo "No sound card has a '${pre[0]} DAC Switch' control." >&2; exit 1; }
get() { amixer -D hw:$card cget name="$1 DAC Switch" | sed -n 's/^  : values=//p'; }

# The speaker sink, and its channel layout: the test file is played with the
# same layout so that PipeWire passes every channel straight through.
read -r sink pos <<< "$(pw-dump | python3 -c '
import json, sys
want = sys.argv[1]
for o in json.load(sys.stdin):
    p = o.get("info", {}).get("props", {})
    if p.get("media.class") != "Audio/Sink": continue
    if (want and p.get("node.name") == want) or (not want and "speaker" in p.get("node.name", "").lower()):
        params = o.get("info", {}).get("params", {})
        pos = next((f.get("position") for f in params.get("EnumFormat", []) + params.get("Format", []) if f.get("position")), None)
        print(p["node.name"], ",".join(pos) if pos else "FL,FR"); break
' "${SINK:-}")"
[ -n "${sink:-}" ] || { echo "No speaker sink found; set SINK=<node.name> (see 'wpctl status')." >&2; exit 1; }
nch=$(awk -F, '{print NF}' <<< "$pos")

# Set the switches with the sink suspended: "<prefix>=on|off" ...
setsw() {
    pactl suspend-sink "$sink" 1; sleep 1
    for kv in "$@"; do amixer -q -D hw:$card cset name="${kv%=*} DAC Switch" "${kv#*=}"; done
    sleep 0.2; pactl suspend-sink "$sink" 0; sleep 0.5
}

tmp=$(mktemp -d)
declare -a orig
for p in "${pre[@]}"; do orig+=("$p=$(get "$p")"); done
restore() { setsw "${orig[@]}" 2>/dev/null || true; rm -rf "$tmp"; }
trap restore EXIT INT TERM

python3 - "$tmp/tone.wav" "$nch" <<'EOF'
import sys, wave, struct, math
R = 48000; A = 0.2; ch = int(sys.argv[2]); out = []
ID = [1000, 1100, 1300, 1400, 1600, 1700, 1900, 2100][:ch]
def seg(d, fs):
    n = int(R * d); fade = int(R * 0.02)
    for i in range(n):
        g = min(1, i / fade, (n - 1 - i) / fade)
        out.append(struct.pack("<%dh" % ch, *(int(32767 * A * g * math.sin(2 * math.pi * f * i / R)) if f else 0 for f in fs)))
seg(1, [0] * ch); seg(1.5, ID); seg(0.5, [0] * ch); seg(3, [300] * ch); seg(0.5, [0] * ch); seg(3, [3000] * ch)
w = wave.open(sys.argv[1], "wb"); w.setnchannels(ch); w.setsampwidth(2); w.setframerate(R)
w.writeframes(b"".join(out))
EOF

echo "Card $card, sink $sink ($pos). Amps:"
for i in "${!pre[@]}"; do printf '  %-6s address %s  %s\n' "${bus[$i]}" "${adr[$i]}" "${pre[$i]}"; done
echo
[ "$mode" = record ] && echo "Recording from the default source; keep the room quiet." || \
    echo "Listen at the left and right ends of the base (or hold a phone with a spectrum app there)."

for i in "${!pre[@]}"; do
    t=${pre[$i]}
    echo
    read -r -p "${bus[$i]} address ${adr[$i]} ($t): Enter to play (channel tones, 300 Hz, 3 kHz). " _
    sw=(); for p in "${pre[@]}"; do [ "$p" = "$t" ] && sw+=("$p=on") || sw+=("$p=off"); done
    # Start recording first: the microphone takes a moment to wake up.
    [ "$mode" = record ] && { pw-record --rate 48000 --channels 1 --format s16 "$tmp/rec-$i.wav" & rec=$!; }
    setsw "${sw[@]}"
    pw-play --target "$sink" --channels "$nch" --channel-map "$pos" "$tmp/tone.wav"
    [ "$mode" = record ] && { sleep 0.3; kill -INT $rec; wait $rec || true; }
done
setsw "${orig[@]}"

if [ "$mode" = record ]; then
    echo
    echo "At the microphone (dB above the silence before the 300 Hz tone):"
    printf '  %-6s %-8s %-16s %-14s %7s %7s %8s\n' bus address prefix "channel" "300 Hz" "3 kHz" "300-3k"
    for i in "${!pre[@]}"; do
        python3 - "$tmp/rec-$i.wav" "${bus[$i]}" "${adr[$i]}" "${pre[$i]}" "$pos" <<'EOF'
import sys, wave, struct, math
w = wave.open(sys.argv[1]); R = w.getframerate(); n = w.getnframes()
x = struct.unpack("<%dh" % n, w.readframes(n)); W = R // 20
pos = sys.argv[5].split(","); ID = [1000, 1100, 1300, 1400, 1600, 1700, 1900, 2100][:len(pos)]
def g(s, f):
    k = 2 * math.cos(2 * math.pi * f / R); a = b = 0.0
    for v in s: a, b = v + k * a - b, a
    return max(a * a + b * b - k * a * b, 1e-9) / len(s) ** 2
wins = [x[i:i + W] for i in range(0, n - W, W)]
def med(v): v = sorted(v); return v[len(v) // 2]
# Every amp plays 3 kHz clearly: find where it starts, and place the rest from there.
e3 = [g(s, 3000) for s in wins]; q = sorted(e3)[len(e3) // 4]
t3 = next((i for i in range(len(e3) - 10) if all(v > 30 * q for v in e3[i:i + 10])), None)
if t3 is None or t3 < 110:
    print("  %-6s %-8s %-16s no sound found, run again" % tuple(sys.argv[2:5])); sys.exit()
sil = range(t3 - 79, t3 - 71)                      # the 0.5 s gap before 300 Hz
def level(f, a, b):
    return 10 * math.log10(med([g(wins[i], f) for i in range(a, b)]) / med([g(wins[i], f) for i in sil]))
ids = [level(f, t3 - 108, t3 - 82) for f in ID]     # the channel tones
best = max(range(len(ids)), key=lambda j: ids[j])
other = max([v for j, v in enumerate(ids) if j != best] or [0])
chan = "%d %s (+%.0f)" % (best + 1, pos[best], ids[best] - other)
lo, hi = level(300, t3 - 66, t3 - 14), level(3000, t3 + 4, t3 + 56)
note = "" if hi > 25 and ids[best] - other > 15 else "  <- no clear signal, run again"
print("  %-6s %-8s %-16s %-14s %7.1f %7.1f %+8.1f%s" % (sys.argv[2], sys.argv[3], sys.argv[4], chan, lo, hi, lo - hi, note))
EOF
    done
    echo
    echo "channel: the channel whose tone came through (+dB over the next one)."
    echo "A woofer has a much higher 300-3k value than a tweeter."
fi
echo
echo "Note for each amp which end of the base it played from, and whether 300 Hz was clearly audible."
