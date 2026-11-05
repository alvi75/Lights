#!/usr/bin/env bash
# Capture an animated demo of the Lights window cycling through states.
# Requires Lights.app to be running and ffmpeg installed (`brew install ffmpeg`).
# Output: docs/demo.gif (~75KB) + docs/demo.mp4 (~80KB).
set -euo pipefail
cd "$(dirname "$0")/.."

AUTH=(-H "@$HOME/.lights/auth")
if ! curl -s --max-time 1 "${AUTH[@]}" http://127.0.0.1:9876/status >/dev/null; then
    echo "✗ Lights not running. Launch Lights.app first." >&2
    exit 1
fi

# The light shows the tab it follows, so the states go to that tab.
TAB=$(osascript -e 'tell application id "com.apple.Terminal" to tty of selected tab of front window' 2>/dev/null \
    || tty 2>/dev/null || true)
TAB=${TAB#/dev/}
case $TAB in ttys*) ;; *) echo "✗ Run this from a Terminal tab." >&2; exit 1 ;; esac

if ! command -v ffmpeg >/dev/null; then
    echo "✗ ffmpeg not installed. brew install ffmpeg" >&2
    exit 1
fi

FRAMES=$(mktemp -d)
trap "rm -rf $FRAMES" EXIT

STATES=("idle" "executing" "permission" "executing" "idle")

shown_as() {
    case $1 in idle) echo done ;; executing) echo working ;; permission) echo needs-you ;; esac
}

# The app re-checks tabs every 2 s and may put the real state back; set until it shows.
show() {
    for _ in 1 2 3 4 5; do
        curl -s "${AUTH[@]}" "http://127.0.0.1:9876/state?s=$1&tab=$TAB" >/dev/null
        sleep 0.4
        [ "$(curl -s "${AUTH[@]}" http://127.0.0.1:9876/status)" = "$(shown_as "$1")" ] && return 0
    done
    return 1
}

echo "→ Capturing 5 frames…"
for i in "${!STATES[@]}"; do
    state="${STATES[$i]}"
    n=$(printf "%02d" $((i+1)))
    show "$state" || { echo "✗ frame $n ($state): the light didn't change"; exit 1; }
    SNAP=$(curl -s "${AUTH[@]}" http://127.0.0.1:9876/snapshot)
    [ -f "$SNAP" ] || { echo "✗ frame $n ($state) failed: $SNAP"; exit 1; }
    cp "$SNAP" "$FRAMES/frame_$n.png"
    rm -f "$SNAP"
    echo "  ✓ frame_$n.png ← $state"
done

mkdir -p docs

echo "→ Building GIF…"
ffmpeg -y -framerate 1 -i "$FRAMES/frame_%02d.png" \
    -vf "scale=120:-1:flags=lanczos,palettegen=stats_mode=full" \
    "$FRAMES/palette.png" >/dev/null 2>&1
ffmpeg -y -framerate 1 -i "$FRAMES/frame_%02d.png" -i "$FRAMES/palette.png" \
    -lavfi "scale=120:-1:flags=lanczos[x];[x][1:v]paletteuse" \
    -loop 0 docs/demo.gif >/dev/null 2>&1

echo "→ Building MP4…"
ffmpeg -y -framerate 1 -i "$FRAMES/frame_%02d.png" \
    -vf "scale=240:-2:flags=lanczos,fps=30" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart \
    docs/demo.mp4 >/dev/null 2>&1

curl -s "${AUTH[@]}" "http://127.0.0.1:9876/state?s=idle&tab=$TAB" >/dev/null

echo
echo "✓ Done:"
ls -lh docs/demo.gif docs/demo.mp4
