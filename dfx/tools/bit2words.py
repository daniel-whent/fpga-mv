"""Convert a Xilinx .bit file to the raw configuration data the HWICAP loader expects.

Output file layout: 4-byte little-endian word count, then the raw configuration bytes exactly as
they appear in the .bit payload (big-endian 32-bit words, first word 0xFFFFFFFF or 0xAA995566 sync).
The MicroBlaze loader byte-swaps each word before writing it to the HWICAP write FIFO.

Usage: python bit2words.py in.bit out.bin
"""
import struct
import sys

def payload(path):
    d = open(path, "rb").read()
    pos = 0
    n = struct.unpack(">H", d[pos:pos + 2])[0]; pos += 2 + n          # magic field
    pos += 2                                                           # 0x0001
    while True:
        key = d[pos:pos + 1]; pos += 1
        if key == b"e":
            length = struct.unpack(">I", d[pos:pos + 4])[0]; pos += 4
            return d[pos:pos + length]
        l = struct.unpack(">H", d[pos:pos + 2])[0]; pos += 2 + l      # a,b,c,d string fields

if __name__ == "__main__":
    data = payload(sys.argv[1])
    assert len(data) % 4 == 0
    assert b"\xaa\x99\x55\x66" in data[:64], "sync word not near start; unexpected .bit layout"
    open(sys.argv[2], "wb").write(struct.pack("<I", len(data) // 4) + data)
    print(f"{sys.argv[1]} -> {sys.argv[2]}: {len(data)} bytes, {len(data) // 4} words")
