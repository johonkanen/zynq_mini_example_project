#!/usr/bin/env python3
"""tftp_server.py [-d DIR] [-p PORT] [-b ADDR] - minimal read-only TFTP server.

Serves the files in DIR (default: build_tftp/ next to this repo's linux/) for
U-Boot's tftpboot - e.g. the reflash.scr / sdcard.img payload made by
linux/reflash-sd.sh. Standard library only, so it runs on Windows (where the
board can reach it; WSL2's NAT hides a server inside WSL from the LAN) as well
as on Linux:

    python linux\\tftp_server.py -d \\\\wsl.localhost\\Ubuntu\\home\\...\\build_tftp

Supports RFC 1350 read requests (octet), the blksize/tsize/timeout options
(RFC 2347-2349), and block-number rollover past 65535 (wraps to 0, as U-Boot
expects), so files larger than 32 MB/96 MB work. Write requests are refused.
Port 69 needs root on Linux; on Windows it doesn't, but Windows Firewall must
allow inbound UDP for the python executable.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

RRQ, WRQ, DATA, ACK, ERROR, OACK = 1, 2, 3, 4, 5, 6
RETRIES = 6


def log(msg):
    print(time.strftime('%H:%M:%S'), msg, flush=True)


def err_packet(code, msg):
    return struct.pack('!HH', ERROR, code) + msg.encode() + b'\0'


def parse_request(pkt):
    parts = pkt[2:].split(b'\0')
    fname, mode = parts[0].decode(errors='replace'), parts[1].decode().lower()
    opts = {}
    for i in range(2, len(parts) - 1, 2):
        if parts[i]:
            opts[parts[i].decode().lower()] = parts[i + 1].decode()
    return fname, mode, opts


def serve(root, client, pkt, bind):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((bind, 0))
    sock.connect(client)
    try:
        fname, mode, opts = parse_request(pkt)
        path = os.path.normpath(os.path.join(root, fname.lstrip('/\\')))
        if not path.startswith(os.path.normpath(root) + os.sep) or not os.path.isfile(path):
            sock.send(err_packet(1, 'file not found'))
            log(f'{client[0]}: RRQ {fname!r} - not found')
            return
        size = os.path.getsize(path)
        blksize, timeout, oack = 512, 1.0, {}
        if 'blksize' in opts:
            blksize = max(8, min(int(opts['blksize']), 65464))
            oack['blksize'] = str(blksize)
        if 'timeout' in opts:
            timeout = max(1, min(int(opts['timeout']), 255))
            oack['timeout'] = str(int(timeout))
        if 'tsize' in opts:
            oack['tsize'] = str(size)
        sock.settimeout(timeout)
        log(f'{client[0]}: RRQ {fname} ({size} B, blksize {blksize}, mode {mode})')

        def exchange(packet, want_block):
            """send packet, wait for ACK of want_block (mod 65536); retransmit on timeout"""
            for _ in range(RETRIES):
                sock.send(packet)
                deadline = time.monotonic() + timeout
                while True:
                    left = deadline - time.monotonic()
                    if left <= 0:
                        break
                    sock.settimeout(left)
                    try:
                        r = sock.recv(1024)
                    except socket.timeout:
                        break
                    op = struct.unpack('!H', r[:2])[0]
                    if op == ERROR:
                        raise RuntimeError('client error: ' + r[4:-1].decode(errors='replace'))
                    if op == ACK and struct.unpack('!H', r[2:4])[0] == want_block:
                        return
                    # duplicate/old ACK: keep waiting for the right one
            raise RuntimeError(f'timeout waiting for ACK {want_block}')

        if oack:
            body = b''.join(k.encode() + b'\0' + v.encode() + b'\0' for k, v in oack.items())
            exchange(struct.pack('!H', OACK) + body, 0)

        t0, sent, block = time.monotonic(), 0, 1
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(blksize)
                exchange(struct.pack('!HH', DATA, block & 0xFFFF) + chunk, block & 0xFFFF)
                sent += len(chunk)
                if len(chunk) < blksize:
                    break
                block += 1
        dt = time.monotonic() - t0
        log(f'{client[0]}: sent {fname} {sent} B in {dt:.1f} s ({sent / dt / 1e6 if dt else 0:.2f} MB/s)')
    except Exception as e:  # report and drop this transfer, keep serving
        log(f'{client[0]}: transfer failed: {e}')
    finally:
        sock.close()


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('-d', '--dir', default=os.path.join(here, '..', 'build_tftp'))
    ap.add_argument('-p', '--port', type=int, default=69)
    ap.add_argument('-b', '--bind', default='0.0.0.0')
    a = ap.parse_args()
    root = os.path.abspath(a.dir)
    if not os.path.isdir(root):
        sys.exit(f'no such directory: {root}')
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((a.bind, a.port))
    log(f'serving {root} on udp/{a.port}')
    while True:
        pkt, client = s.recvfrom(2048)
        op = struct.unpack('!H', pkt[:2])[0]
        if op == RRQ:
            threading.Thread(target=serve, args=(root, client, pkt, a.bind), daemon=True).start()
        elif op == WRQ:
            s.sendto(err_packet(2, 'read-only server'), client)


if __name__ == '__main__':
    main()
