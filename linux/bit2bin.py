#!/usr/bin/env python3
"""bit2bin.py <in.bit> <out.bin> - Vivado .bit -> raw .bin for the Linux Zynq
FPGA manager (fpgautil / /sys/class/fpga_manager).

The zynq-fpga driver rejects a .bit (-EINVAL): it wants the configuration data
without the .bit header, with every 32-bit word byte-swapped so the sync word
reads AA 99 55 66 -> 66 55 99 AA. Same result as
  bootgen -arch zynq -process_bitstream bin
"""
import struct, sys

def bit_payload(d: bytes) -> bytes:
    # header: 2-byte length + magic, 2-byte 0x0001, then keyed fields 'a'..'d'
    # (2-byte length each) and 'e' (4-byte length) followed by the raw data
    n = struct.unpack('>H', d[0:2])[0]
    i = 2 + n
    i += 2                                   # 0x0001 'a'-key length field
    while True:
        key = d[i:i + 1]; i += 1
        if key == b'e':
            ln = struct.unpack('>I', d[i:i + 4])[0]; i += 4
            data = d[i:i + ln]
            if len(data) != ln:
                raise SystemExit('truncated .bit')
            return data
        if key not in (b'a', b'b', b'c', b'd'):
            raise SystemExit(f'unexpected .bit field {key!r} at {i - 1}')
        ln = struct.unpack('>H', d[i:i + 2])[0]; i += 2 + ln

def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    data = bit_payload(open(sys.argv[1], 'rb').read())
    if len(data) % 4:
        raise SystemExit('bitstream length not a multiple of 4')
    out = bytearray(len(data))
    out[0::4], out[1::4], out[2::4], out[3::4] = data[3::4], data[2::4], data[1::4], data[0::4]
    while len(out) % 8:                      # pad with NOOPs like bootgen does
        out += bytes.fromhex('00000020')
    if bytes(out).find(bytes.fromhex('665599aa')) < 0:
        raise SystemExit('no sync word found - not a 7-series bitstream?')
    open(sys.argv[2], 'wb').write(out)

if __name__ == '__main__':
    main()
