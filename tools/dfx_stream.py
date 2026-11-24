"""Host side of software/dfx_stream: push a frame to the board, run it through the reconfigurable partition
(RM A grayscale / RM B invert), read the result back and check it against a local reference model.

The DFX design only has the console UART Lite (115200 8N1), so a 640x480x3 frame (921600 bytes) takes ~80 s each way.

Wire protocol (commands are single bytes on the console UART; existing ones are already in software/dfx_stream):
  existing   a / b   swap to RM A / RM B, then run + verify a frame on the board   -> ... "VERIFY ... OK|FAIL"
             g       run the current module on the frame in DDR2 and verify        -> ... "VERIFY ... OK|FAIL"
             z       toggle the module's bypass register, run + verify
  NEW (to be added to the firmware, see PROTOCOL below):
             'S' + len[3, LE]   board replies "R\\r\\n", receives len bytes into SRC_ADDR, replies "D <len> <sum32 hex>\\r\\n"
             'U' + len[3, LE]   board replies "R\\r\\n", sends len bytes from DST_ADDR, then "D <len> <sum32 hex>\\r\\n"
  sum32 = sum of all bytes mod 2^32. Pixels are 3 bytes per pixel in the order G, B, R.

Examples:
  python dfx_stream.py --port COM4 --pattern bars --module a          # swap to grayscale, send, run, read back, compare
  python dfx_stream.py --port COM4 photo.jpg --module b --save out.png
  python dfx_stream.py --port COM4 --pattern bars --module b --send-only
  python dfx_stream.py --port COM4 --run-only --module a --readback     # reuse the frame already in DDR2
Needs: pip install pyserial pillow numpy
"""
import argparse
import sys
import time

import numpy as np

from send_frame import H, W, load_image, pattern_bars, to_framebuffer_bytes

BAUD = 115_200
CHUNK = 256            # bytes per write; keeps progress output smooth and the UART Lite's 16-byte FIFO fed by the OS


# ---------------------------------------------------------------- reference model (must match verify_frame in main.c)
def reference(data: bytes, module: str, bypass: bool = False) -> bytes:
    """Expected output of the partition for a frame in G,B,R byte order."""
    a = np.frombuffer(data, np.uint8)
    if bypass:
        return bytes(a)
    px = a.reshape(-1, 3).astype(np.uint32)
    if module == "a":      # grayscale: y = (77 R + 150 G + 29 B) >> 8, written to all three bytes
        g, b, r = px[:, 0], px[:, 1], px[:, 2]
        y = ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)
        return np.repeat(y[:, None], 3, axis=1).tobytes()
    if module == "b":      # invert
        return (~a).tobytes()
    raise ValueError(module)


def sum32(data: bytes) -> int:
    return int(np.frombuffer(data, np.uint8).sum(dtype=np.uint64) & 0xFFFFFFFF)


# ---------------------------------------------------------------- board link
class Board:
    def __init__(self, port, baud=BAUD):
        import serial
        self.ser = serial.Serial(port, baud, timeout=0.2, write_timeout=60)
        self.rx = bytearray()          # bytes read from the port but not consumed yet (payload can follow a token)

    def close(self):
        self.ser.close()

    def flush_input(self):
        self.ser.reset_input_buffer()
        self.rx.clear()

    def sync(self):
        """Throw away anything pending (boot banner, earlier output)."""
        time.sleep(0.1)
        self.flush_input()

    def _fill(self):
        self.rx += self.ser.read(self.ser.in_waiting or 1)

    def _take_until(self, token: bytes, timeout: float) -> bytes:
        """Consume and return everything up to and including `token`; bytes after it stay in the buffer."""
        end = time.time() + timeout
        while True:
            i = self.rx.find(token)
            if i >= 0:
                out = bytes(self.rx[:i + len(token)])
                del self.rx[:i + len(token)]
                return out
            if time.time() > end:
                raise TimeoutError(f"no {token!r} from the board (got {bytes(self.rx)!r})")
            self._fill()

    def _take(self, n: int, stall: float = 5, what="received") -> bytes:
        """Consume exactly n bytes; fail if nothing arrives for `stall` seconds."""
        t0 = last = time.time()
        shown = 0
        while len(self.rx) < n:
            before = len(self.rx)
            self._fill()
            if len(self.rx) > before:
                last = time.time()
            elif time.time() - last > stall:
                raise TimeoutError(f"stalled after {len(self.rx)} of {n} bytes")
            if len(self.rx) - shown >= 16384:
                shown = len(self.rx)
                self._progress(what, shown, n, t0)
        out = bytes(self.rx[:n])
        del self.rx[:n]
        self._progress(what, n, n, t0, end="\n")
        return out

    def _length(self, n):
        if not 0 < n < (1 << 24):
            raise ValueError("length must fit in 3 bytes")
        return n.to_bytes(3, "little")

    def send(self, data: bytes):
        """'S' command: stream `data` into SRC_ADDR and check the board's byte sum."""
        self.flush_input()
        self.ser.write(b"S" + self._length(len(data)))
        self._take_until(b"R\r\n", 5)
        self._write_progress(data)
        reply = self._take_until(b"\n", 10).decode(errors="replace").strip()
        self._check_reply(reply, len(data), sum32(data))

    def receive(self, n: int) -> bytes:
        """'U' command: read n bytes of the result frame back from DST_ADDR."""
        self.flush_input()
        self.ser.write(b"U" + self._length(n))
        self._take_until(b"R\r\n", 5)
        data = self._take(n)
        reply = self._take_until(b"\n", 10).decode(errors="replace").strip()
        self._check_reply(reply, n, sum32(data))
        return data

    def _check_reply(self, reply, n, expected_sum):
        parts = reply.split()
        if len(parts) != 3 or parts[0] != "D":
            raise RuntimeError(f"unexpected board reply {reply!r}")
        if int(parts[1]) != n or int(parts[2], 16) != expected_sum:
            raise RuntimeError(f"byte count / sum mismatch: board says {parts[1]} bytes, sum {parts[2]}; "
                               f"expected {n} bytes, sum {expected_sum:08x}")

    def _write_progress(self, data):
        t0 = time.time()
        for i in range(0, len(data), CHUNK):
            self.ser.write(data[i:i + CHUNK])
            if (i // CHUNK) % 64 == 0:
                self._progress("sent", i, len(data), t0)
        self.ser.flush()
        self._progress("sent", len(data), len(data), t0, end="\n")

    def _progress(self, what, done, total, t0, end="\r"):
        el = max(time.time() - t0, 1e-6)
        print(f"  {what} {done}/{total} bytes ({done / el / 1000:.1f} kB/s)", end=end, flush=True)

    def run(self, module: str | None, bypass_toggle: bool = False):
        """Swap/run on the board and return its VERIFY line."""
        cmd = b"z" if bypass_toggle else {"a": b"a", "b": b"b", None: b"g"}[module]
        # swapping reloads a partial bitstream and the board then checks 640x480x3 bytes on a soft CPU: be generous
        self.flush_input()
        self.ser.write(cmd)
        text, end = "", time.time() + 120
        while time.time() < end:
            text += self.ser.read(self.ser.in_waiting or 1).decode(errors="replace")
            # the board ends a run with a "VERIFY ..." line, or with one of its error messages
            for line in text.splitlines(keepends=True):
                if line.endswith("\n") and line.startswith(RUN_END):
                    return text
        raise TimeoutError(f"no result line from the board (got {text!r})")


RUN_END = ("VERIFY", "TIMEOUT", "DMA error", "bad word count", "shutdown manager")


# ---------------------------------------------------------------- frames
def make_frame(args) -> bytes:
    if args.pattern == "bars":
        rgb = pattern_bars()
    elif args.pattern == "gradient":
        rgb = np.zeros((H, W, 3), np.uint8)
        rgb[..., 0] = np.linspace(0, 255, W, dtype=np.uint8)[None, :]
        rgb[..., 1] = np.linspace(0, 255, H, dtype=np.uint8)[:, None]
        rgb[..., 2] = 255 - rgb[..., 0]
    elif args.pattern == "random":
        rgb = np.random.default_rng(args.seed).integers(0, 256, (H, W, 3), dtype=np.uint8)
    elif args.image:
        rgb = load_image(args.image)
    else:
        raise SystemExit("give an image file or --pattern bars/gradient/random")
    return to_framebuffer_bytes(rgb)


def compare(expected: bytes, got: bytes) -> bool:
    e, g = np.frombuffer(expected, np.uint8), np.frombuffer(got, np.uint8)
    bad = np.flatnonzero(e != g)
    if bad.size == 0:
        print(f"PC check: all {e.size} bytes match the reference model")
        return True
    first = int(bad[0])
    print(f"PC check: {bad.size} of {e.size} bytes differ, first at offset {first} "
          f"(pixel {first // 3}, x={first // 3 % W}, y={first // 3 // W}): expected {e[first]}, got {g[first]}")
    return False


def save_png(path, data: bytes):
    from PIL import Image
    a = np.frombuffer(data, np.uint8).reshape(H, W, 3)       # G,B,R -> R,G,B
    Image.fromarray(np.stack([a[..., 2], a[..., 0], a[..., 1]], axis=-1)).save(path)
    print(f"saved {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", nargs="?", help="image file (jpg/png/...)")
    ap.add_argument("--port", default="COM4")
    ap.add_argument("--pattern", choices=["bars", "gradient", "random"])
    ap.add_argument("--seed", type=int, default=1, help="seed for --pattern random")
    ap.add_argument("--module", choices=["a", "b"],
                    help="swap to RM A (grayscale) or RM B (invert) first; also selects the reference model. "
                         "Without it the current module is used (give it anyway so the PC knows which to expect)")
    ap.add_argument("--send-only", action="store_true", help="only transfer the frame to DDR2")
    ap.add_argument("--run-only", action="store_true", help="skip the transfer; use the frame already in DDR2")
    ap.add_argument("--readback", action="store_true", help="with --run-only: also read the result back and compare")
    ap.add_argument("--save", metavar="PNG", help="save the result frame as a PNG")
    args = ap.parse_args()
    if not args.run_only and not (args.image or args.pattern):
        ap.error("give an image file or --pattern, or use --run-only")
    if (args.run_only or not args.send_only) and not args.module:
        ap.error("--module a|b is needed so the PC knows the expected result (or use --send-only)")

    board = Board(args.port)
    ok = True
    try:
        board.sync()
        data = None
        if not args.run_only:
            data = make_frame(args)
            print(f"sending {len(data)} bytes at {BAUD} baud (~{len(data) * 10 / BAUD:.0f} s)")
            board.send(data)
            print("board has the frame, byte sum matches")
        if args.send_only:
            return 0
        print(board.run(args.module).strip())
        if data is not None or args.readback:
            n = W * H * 3
            print(f"reading result back (~{n * 10 / BAUD:.0f} s)")
            got = board.receive(n)
            if data is not None:
                ok = compare(reference(data, args.module), got)
            if args.save:
                save_png(args.save, got)
    finally:
        board.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
