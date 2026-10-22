#!/usr/bin/env python3
"""
pl_udp.py - talk to the FPGA's own UDP endpoint (src/hdl/eth_mac.vhd, PL_ETH=hvhdl build)
over the PL Ethernet port: no Linux in the path. doc/hvhdl_ethernet.md, phase 4.

    pl_udp.py read 0x1c                      read an axi_regs register (0x00..0xFF)
    pl_udp.py write 0x00 0x12345678          write one
    pl_udp.py stream 10000 1472              ask for a stream, measure what arrives
    pl_udp.py scope [--arm] [--csv file]     fetch the oscilloscope's capture (4 x 4096 samples)

Options: --ip (default 192.168.20.10), --port (5000). Works from Windows and from WSL
(through its NAT) alike - it's plain UDP.
"""
import argparse
import socket
import struct
import sys
import time

SCOPE_CMD, SCOPE_STAT = 0x40, 0x44
SAMPLES, CHANNELS, PER_DATAGRAM = 4096, 4, 128


class PL:
    def __init__(self, ip="192.168.20.10", port=5000, timeout=0.5):
        self.addr = (ip, port)
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
        self.s.bind(("", 0))
        self.s.settimeout(timeout)

    def _ask(self, request, tries=3):
        for _ in range(tries):
            self.s.sendto(request, self.addr)
            try:
                reply, _ = self.s.recvfrom(2048)
                return reply
            except socket.timeout:
                continue
        raise TimeoutError(f"no reply from {self.addr[0]}:{self.addr[1]}")

    def read(self, addr):
        r = self._ask(struct.pack(">BH", 2, addr))
        cmd, _, a, value = struct.unpack(">BBHI", r[:8])
        assert cmd == 2 and a == addr, r[:8].hex()
        return value

    def write(self, addr, value):
        r = self._ask(struct.pack(">BHI", 3, addr, value))
        cmd, _, a, v = struct.unpack(">BBHI", r[:8])
        assert cmd == 3 and a == addr and v == value, r[:8].hex()

    def stream(self, count, size):
        self.s.sendto(struct.pack(">BIH", 1, count, size), self.addr)
        got, lost, last, t0, t1 = 0, 0, -1, None, None
        buf = bytearray(2048)
        while True:
            try:
                n = self.s.recv_into(buf)
            except socket.timeout:
                break
            t = time.perf_counter()
            t0 = t0 or t
            t1 = t
            seq = struct.unpack_from(">I", buf)[0]
            lost += seq - last - 1 if seq > last else 0
            last = seq
            got += 1
        rate = (got - 1) * size * 8 / (t1 - t0) / 1e6 if got > 1 and t1 > t0 else 0
        return got, count - got, rate

    def scope(self, arm=False, wait=2.0):
        """the last capture as 4 lists of 4096 int16 (ch0..ch3), the trigger at the pre index"""
        if arm:
            self.write(SCOPE_CMD, 1)
            t_end = time.time() + wait
            while not self.read(SCOPE_STAT) & 4:
                if time.time() > t_end:
                    raise TimeoutError("the capture did not finish (no trigger?)")
                time.sleep(0.01)
        self.s.sendto(bytes([4]), self.addr)
        parts = {}
        while len(parts) < SAMPLES // PER_DATAGRAM:
            try:
                d, _ = self.s.recvfrom(2048)
            except socket.timeout:
                break
            if d[:2] == b"\x04\xff":
                raise RuntimeError("no capture done - arm the scope first (--arm)")
            offset, total = struct.unpack(">HH", d[:4])
            parts[offset] = d[4:]
        if len(parts) != SAMPLES // PER_DATAGRAM:
            raise RuntimeError(f"got {len(parts)} of {SAMPLES // PER_DATAGRAM} datagrams")
        raw = b"".join(parts[o] for o in sorted(parts))
        flat = struct.unpack(f"<{SAMPLES * CHANNELS}h", raw)
        return [list(flat[k::CHANNELS]) for k in range(CHANNELS)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", default="192.168.20.10")
    ap.add_argument("--port", type=int, default=5000)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("read"); p.add_argument("addr", type=lambda x: int(x, 0))
    p = sub.add_parser("write"); p.add_argument("addr", type=lambda x: int(x, 0)); p.add_argument("value", type=lambda x: int(x, 0))
    p = sub.add_parser("stream"); p.add_argument("count", type=int); p.add_argument("size", type=int)
    p = sub.add_parser("scope"); p.add_argument("--arm", action="store_true"); p.add_argument("--csv")
    a = ap.parse_args()
    pl = PL(a.ip, a.port, timeout=1.0 if a.cmd in ("stream", "scope") else 0.5)
    if a.cmd == "read":
        print(f"0x{pl.read(a.addr):08x}")
    elif a.cmd == "write":
        pl.write(a.addr, a.value)
    elif a.cmd == "stream":
        got, missing, rate = pl.stream(a.count, a.size)
        print(f"received {got}/{a.count} datagrams of {a.size} bytes ({missing} missing), {rate:.0f} Mbit/s at this end")
    elif a.cmd == "scope":
        t0 = time.perf_counter()
        ch = pl.scope(arm=a.arm)
        print(f"capture: {CHANNELS} x {SAMPLES} samples in {(time.perf_counter() - t0) * 1e3:.1f} ms; "
              + "  ".join(f"ch{k} {min(c)}..{max(c)}" for k, c in enumerate(ch)))
        if a.csv:
            with open(a.csv, "w") as f:
                f.write("sample,ch0,ch1,ch2,ch3\n")
                for i in range(SAMPLES):
                    f.write(f"{i},{ch[0][i]},{ch[1][i]},{ch[2][i]},{ch[3][i]}\n")


if __name__ == "__main__":
    sys.exit(main())
