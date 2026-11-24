"""Send a 640x480 frame to the Nexys A7 framebuffer over the USB-UART bridge at 4 Mbaud.

Protocol (matches software/usb_frame):
  1. at 115200:  'F' + 3-byte little-endian length      -> board arms the DMA and replies 'R\\n'
  2. switch to 4 Mbaud and stream the pixel bytes (the board's fast receiver is enabled only now)
  3. switch back to 115200                              -> board replies 'D <rx status> <dma status>\\n'
Pixel format in memory: 3 bytes per pixel in the order G, B, R (Xilinx video 'RGB' packing), 640 bytes*3 per line.

Examples:
  python send_frame.py --port COM4 --pattern bars
  python send_frame.py --port COM4 photo.jpg
Needs: pip install pyserial pillow numpy
"""
import argparse
import sys
import time

import numpy as np
import serial

W, H = 640, 480
FAST_BAUD = 4_000_000
SLOW_BAUD = 115_200


def pattern_bars():
    img = np.zeros((H, W, 3), np.uint8)
    colors = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
              (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    for i, c in enumerate(colors):
        img[: H * 2 // 3, i * W // 8:(i + 1) * W // 8] = c
    ramp = np.linspace(0, 255, W, dtype=np.uint8)
    img[H * 2 // 3:, :, :] = ramp[None, :, None]
    return img


def load_image(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    # fit inside 640x480 keeping aspect ratio, black borders
    im.thumbnail((W, H))
    canvas = Image.new("RGB", (W, H))
    canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
    return np.asarray(canvas, np.uint8)


def to_framebuffer_bytes(rgb):
    """RGB array (H,W,3) -> bytes in G, B, R order per pixel."""
    return np.stack([rgb[..., 1], rgb[..., 2], rgb[..., 0]], axis=-1).tobytes()


def read_until(ser, token, timeout):
    end = time.time() + timeout
    buf = b""
    while time.time() < end:
        buf += ser.read(ser.in_waiting or 1)
        if token in buf:
            return buf
    raise TimeoutError(f"no {token!r} from the board (got {buf!r})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", nargs="?", help="image file (jpg/png/...)")
    ap.add_argument("--port", default="COM4")
    ap.add_argument("--pattern", choices=["bars"], help="send a built-in test pattern instead of an image")
    ap.add_argument("--baud", type=int, default=FAST_BAUD)
    args = ap.parse_args()

    if args.pattern == "bars":
        rgb = pattern_bars()
    elif args.image:
        rgb = load_image(args.image)
    else:
        ap.error("give an image file or --pattern bars")
    data = to_framebuffer_bytes(rgb)
    n = len(data)

    ser = serial.Serial(args.port, SLOW_BAUD, timeout=0.2, write_timeout=60)
    ser.reset_input_buffer()
    ser.write(b"F" + n.to_bytes(3, "little"))
    read_until(ser, b"R\r\n", 5)
    t0 = time.time()
    ser.baudrate = args.baud
    time.sleep(0.01)
    ser.write(data)
    ser.flush()
    t1 = time.time()
    time.sleep(0.01)
    ser.baudrate = SLOW_BAUD
    reply = read_until(ser, b"\n", 10)
    # reply is typically "D <rx status> <dma status>\n"
    print(f"sent {n} bytes in {t1 - t0:.2f} s ({n / (t1 - t0) / 1000:.0f} kB/s); board: {reply.decode(errors='replace').strip()}")
    ser.close()


if __name__ == "__main__":
    sys.exit(main())
