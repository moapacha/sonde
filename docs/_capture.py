#!/usr/bin/env python3
"""
Capture frames from a real norns running sonde, then stitch a GIF.

Path:
  WS REPL on norns -> clock.run loop -> screen.export_screenshot per tick
  -> dust/data/sonde/frame_NNN.png on the device
  -> SCP back to docs/_frames/
  -> gamma-correct + ffmpeg into docs/screen.gif

Run from repo root.
"""
import os
import shutil
import subprocess
import sys
import time
import websocket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAME_DIR = os.path.join(ROOT, "docs", "_frames")
GIF_OUT   = os.path.join(ROOT, "docs", "screen.gif")
PNG_OUT   = os.path.join(ROOT, "docs", "screen.png")

NORNS_HOST   = "norns.local"
SUBPROTO     = ["bus.sp.nanomsg.org"]
N_FRAMES     = 30
FRAME_DT     = 0.20    # seconds between captures on device
TEMPO_HZ     = 4       # set during capture
N_SATS       = 2
WARMUP       = 6.0     # seconds for the orbit to draw some trail before capture
GIF_FPS      = 12      # playback rate
GAMMA        = 0.55    # < 1 brightens dim levels (norns OLED gamma compensation)


def ws_connect():
    ws = websocket.create_connection(
        f"ws://{NORNS_HOST}:5555",
        subprotocols=SUBPROTO,
        timeout=5,
    )
    ws.settimeout(1.5)
    return ws


def drain(ws):
    out = []
    while True:
        try:
            out.append(str(ws.recv()))
        except Exception:
            break
    return "".join(out)


def send(ws, lua):
    ws.send(lua + "\n")
    time.sleep(0.05)


def main():
    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found"); sys.exit(1)

    os.makedirs(FRAME_DIR, exist_ok=True)
    for f in os.listdir(FRAME_DIR):
        if f.startswith("frame_"):
            os.remove(os.path.join(FRAME_DIR, f))

    print("connecting to matron...")
    ws = ws_connect()
    drain(ws)

    print("verifying sonde is loaded")
    send(ws, 'print("LOADED="..tostring(norns.state.script))')
    time.sleep(0.4)
    out = drain(ws)
    if "sonde.lua" not in out:
        print("sonde is not the active script. matron says:", out)
        ws.close(); sys.exit(2)

    print(f"setting n_sats={N_SATS}, tempo={TEMPO_HZ}Hz")
    send(ws, f'params:set("n_sats", {N_SATS})')
    send(ws, f'params:set("tempo", {TEMPO_HZ})')

    print(f"clearing any prior frames on device, warming up {WARMUP}s")
    send(ws, 'os.execute("rm -f /home/we/dust/data/sonde/frame_*.png")')
    time.sleep(WARMUP)
    drain(ws)

    print(f"capturing {N_FRAMES} frames every {FRAME_DT*1000:.0f}ms via clock.run")
    lua = (
        "clock.run(function() "
        f"for i=1,{N_FRAMES} do "
        f'screen.export_screenshot(string.format("frame_%03d", i)); '
        f"clock.sleep({FRAME_DT}) "
        "end; print('CAPTURE_DONE') "
        "end)"
    )
    send(ws, lua)
    deadline = time.time() + N_FRAMES * FRAME_DT + 5
    captured = False
    while time.time() < deadline:
        out = drain(ws)
        if "CAPTURE_DONE" in out:
            captured = True
            break
        time.sleep(0.3)
    if not captured:
        print("did not see CAPTURE_DONE; continuing anyway")

    ws.close()

    print("scp'ing frames back")
    rc = subprocess.run([
        "scp", "-q",
        f"we@{NORNS_HOST}:dust/data/sonde/frame_*.png",
        FRAME_DIR + "/",
    ]).returncode
    if rc != 0:
        print("scp failed"); sys.exit(3)

    frames = sorted(f for f in os.listdir(FRAME_DIR) if f.startswith("frame_"))
    print(f"got {len(frames)} frames")
    if not frames:
        sys.exit(4)

    # gamma-correct + build a palette + write GIF
    palette = os.path.join(FRAME_DIR, "_palette.png")
    vf_in = (
        f"format=gray,"
        f"lutyuv='y=gammaval({GAMMA})',"
        "format=rgb24"
    )
    print("building GIF palette")
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-framerate", str(GIF_FPS),
        "-i", os.path.join(FRAME_DIR, "frame_%03d.png"),
        "-vf", f"{vf_in},palettegen=stats_mode=full",
        palette,
    ], check=True)
    print("encoding GIF")
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-framerate", str(GIF_FPS),
        "-i", os.path.join(FRAME_DIR, "frame_%03d.png"),
        "-i", palette,
        "-lavfi", f"[0:v]{vf_in}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4",
        "-loop", "0",
        GIF_OUT,
    ], check=True)
    print(f"wrote {GIF_OUT}")

    # also drop a single representative still (mid-frame) for static contexts
    mid = frames[len(frames) // 2]
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", os.path.join(FRAME_DIR, mid),
        "-vf", vf_in,
        PNG_OUT,
    ], check=True)
    print(f"wrote {PNG_OUT}")


if __name__ == "__main__":
    main()
