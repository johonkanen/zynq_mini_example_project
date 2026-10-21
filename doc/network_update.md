# Network updates — FPGA, Linux and software

Plan for updating everything on the board over the network:

- the **FPGA** (bitstream and its Linux-side description),
- **Linux** itself (kernel, device tree, rootfs, bootloader),
- **our software** (fpgad, fpga-web, oled-status, configs).

Requirements:

1. **Loading a new FPGA design never reboots Linux**, not even when the design's
   register map or address window changes.
2. **JTAG is never needed**, for updates or for recovery. A failed update must
   recover by itself, or with at most a power cycle.
3. Updates are **signed**: the board installs only bundles built and signed by us.
4. Tooling: **[RAUC](https://rauc.io)** (Buildroot package, v1.15.2) for bundles,
   signatures, A/B slots and artifact repositories.

## Where we start

| | today |
|---|---|
| bitstream | `update-board.sh bit` copies a `.bit.bin` to `/lib/firmware`, `fpgactl load` reloads it — **no reboot**, but no version check and no rollback |
| PL device tree | the `axi_regs` UIO node is in the base dtb, so a design with a different address window needs **a new dtb and a reboot** (happened when the scope grew the window to 64 KB) |
| software | `update-board.sh fpgad|web` copies single files over SSH |
| kernel / dtb | copied to the FAT boot partition, reboot; a bad one needs a reflash |
| rootfs | new packages or `/etc` changes need a reflash |
| recovery | TFTP reflash **driven by U-Boot over JTAG** |
| versions | nothing on the board says what bitstream or software it runs |

Building blocks we already have: the kernel has device-tree overlays and FPGA regions
(`CONFIG_OF_OVERLAY`, `OF_CONFIGFS`, `OF_FPGA_REGION`, `FPGA_BRIDGE`); the base DT has
an `fpga-region` wired to the FPGA manager; the Cadence watchdog driver is built in;
the board has 16 MB of QSPI flash.

## Three layers

| layer | contents | changes | reboot | rollback |
|---|---|---|---|---|
| **PL bundle** | bitstream + DT overlay + manifest | often | **never** | automatic, to the last good design |
| **app bundle** | fpgad, fpga-web, oled-status, configs | often | no — services restart | automatic, to the previous version |
| **OS bundle** | kernel, dtb, rootfs | rarely | yes | A/B slots, automatic fallback |

All three are RAUC bundles signed with the same key. PL and app bundles go into RAUC
**artifact repositories** (installed without touching the root filesystem); OS bundles
go into the inactive **rootfs slot**.

---

## Phase 1 — FPGA updates without a Linux reboot

### 1.1 The PL's device tree becomes an overlay

The `axi_regs` node leaves the base dtb and moves into a **device-tree overlay**
(`linux/pl/zynq-mini-pl.dtso`) that targets the base DT's `fpga-region`:

```dts
/dts-v1/;
/plugin/;
&{/fpga-region} {
    firmware-name = "zynq-mini-pl.bit.bin";     /* loaded from /lib/firmware */
    #address-cells = <1>;
    #size-cells = <1>;
    axi_regs@40000000 {
        compatible = "generic-uio";
        reg = <0x40000000 0x10000>;
    };
};
```

Applying the overlay (configfs, `/sys/kernel/config/device-tree/overlays/pl`) makes
the kernel program the PL first and then create `/dev/uioN` with exactly this
design's address window. Removing it unbinds UIO before the next design goes in.
A design with a different register window ships its own overlay, so the base dtb
never changes for FPGA reasons again.

### 1.2 PL bundle

`linux/make-pl-bundle.sh` turns `output/arm_fpga_zynq_mini.bit` into a signed
RAUC bundle `pl-<version>.raucb` containing one `trees` artifact `pl/design`:

```
design/
  zynq-mini-pl.bit.bin    bitstream for the FPGA manager (linux/bit2bin.py)
  zynq-mini-pl.dtbo       overlay, compiled with dtc -@
  manifest.json           {"version", "build_id", "regmap", "git", "date", "sha256": {...}}
```

The bundle manifest uses `convert=tar-extract`, so the board doesn't need GNU tar.
`compatible=zynq-mini`, so a bundle for another board is refused.

### 1.3 The design says what it is

`axi_regs` gets two read-only registers:

| offset | name | value |
|---|---|---|
| `0x28` | `BUILD_ID` | build timestamp (Unix seconds), set by `scripts/build.tcl` as a VHDL generic |
| `0x2C` | `REGMAP` | register-map version, bumped whenever the map changes incompatibly |

`manifest.json` carries the same two values. After a load, fpgad checks that
`BUILD_ID` matches the manifest (this really is the bitstream from the bundle) and
that it supports `REGMAP` (fpgad and the design agree on the register map).

### 1.4 fpgad loads designs, with trial and automatic rollback

fpgad already owns the PL; it now loads designs through overlays and keeps a known-good
copy:

```
/data/rauc/pl/design  -> <hash>/        RAUC artifact repository: newest installed design
/data/pl/good/                          copy of the last design that passed its checks
/data/pl/trial                          marker: a trial load is in progress (+ its hash)
/lib/firmware/zynq-mini-pl.bit.bin      symlink to the bitstream being loaded
```

`fpgactl activate` (called by RAUC's post-install handler after an install):

1. read the candidate's `manifest.json` and refuse a `REGMAP` this fpgad doesn't
   support (integrity and signature were checked by RAUC at install time; the
   manifest's sha256 values are for humans and tools);
2. write `/data/pl/trial` and `sync`;
3. block all register access, unmap UIO, remove the old overlay, point the firmware
   symlink at the candidate, apply its overlay;
4. wait for its UIO node, map it, check SIGNATURE, `BUILD_ID` and `REGMAP`;
5. **pass**: copy the candidate to `/data/pl/good/`, remove the trial marker;
   **fail**: load `/data/pl/good/` again, remove the marker, report the error.

At boot, fpgad loads `/data/pl/good/`. **If the trial marker is still there**, the
board reset in the middle of a trial — most likely because the new design hung the
bus — so fpgad logs it, drops the marker and stays on the good design.

`S95fpga` goes away; fpgad does the boot-time load (it is the only process that
touches the PL). It also mounts configfs on `/sys/kernel/config` if nothing has
(Buildroot's fstab doesn't).

### 1.5 Hardware watchdog: no hang needs JTAG

A design without a working AXI slave hangs the SoC on the first register read (seen
on this board). The Zynq's watchdog (`cdns,wdt-r1p2`, already in the DT) turns that
into a reset:

- The DT needs `reset-on-timeout` on the watchdog node; without it the Cadence WDT
  only raises an interrupt ("Internal reset not enabled") and nothing resets.
- fpgad opens `/dev/watchdog` and kicks it from a thread **only after a register read
  returned** (or while no design is loaded). A bus hang stalls that thread, the
  watchdog fires, the board resets, and §1.4's trial marker makes it come back on
  the good design.
- If fpgad itself dies, the watchdog also resets the board (it is the core service);
  a clean stop disarms it.

### 1.6 RAUC on the board

- Kernel config fragment `linux/kernel-rauc.config`: `SQUASHFS` (+ XZ/zlib), `MD`,
  `BLK_DEV_DM`, `DM_VERITY`, `CRYPTO_SHA256` — bundles are squashfs images checked
  with dm-verity (without SHA-256: "verity: Cannot initialize hash function").
- Buildroot: `rauc` (target) and `host-rauc` (bundle creation).
- `/etc/rauc/system.conf`: `compatible=zynq-mini`, `bootloader=noop` for now,
  `[artifacts.pl] path=/data/rauc/pl type=trees`, `[handlers] post-install=` →
  `fpgactl activate`, and:
  - `[slot.rootfs.0] device=/dev/mmcblk0p2 readonly=true` — RAUC refuses to install
    anything, even artifacts, until it recognises the booted slot; read-only, so it
    is never written (phase 3 adds the A/B pair);
  - `[keyring] check-purpose=codesign` — the signer certificate must be issued for
    code signing;
  - `[keyring] use-bundle-signing-time=true` — the board has no RTC or NTP and boots
    at 1970, so certificates are checked against the bundle's signing time
    ("certificate is not yet valid" otherwise).
- Signing keys: a development CA and signing certificate generated once by
  `build-linux.sh` in `<build dir>/rauc-keys/` — **outside the repository** (it is
  public). Only the CA certificate (`keyring.pem`) goes into the image.

### 1.7 Tools

```sh
./linux/make-pl-bundle.sh                    # output/*.bit -> output/pl-<ver>.raucb
./linux/update-board.sh <ip> pl output/pl-<ver>.raucb
#   scp + `rauc install` + fpgactl activate; prints the result of the checks
fpgactl pl                                   # running design: build id, regmap, bundle version
```

The web page shows the running design's version next to the PL state.

### 1.8 A fixed MAC address

U-Boot makes up a random MAC on every boot, so the board's DHCP address kept
changing — awkward for SSH and for updates. An early init script (`S38ethaddr`) sets
a fixed locally administered address (`02:5a:4d:00:00:01`; override in
`/etc/default/ethaddr` for a second board) before networking starts.

### 1.9 Getting there (one-time migration, no JTAG)

Phase 1 changes the kernel, the base dtb and the rootfs (new packages), so the board
needs one new SD image. Without JTAG:

1. `linux/reflash-over-ssh.sh <ip>`: copy the kernel and the ramdisk rootfs
   (`rootfs.cpio.uboot`, same image, has SSH) to the FAT partition, boot it once,
   then stream the new `sdcard.img` to `/dev/mmcblk0` over SSH, read it back to
   compare, and reboot. The new card's extlinux.conf has no ramdisk entry, so the
   detour disappears with the old image.
2. Fallback if that fails: take the card out and write it on a PC.

From then on, every FPGA update is a bundle and never reboots Linux.

### 1.10 Status — done, verified on the board (2026-10-21)

| test | result |
|---|---|
| migration with `reflash-over-ssh.sh` (ramdisk detour, 92 MB, read-back md5) | ok, no JTAG |
| kernel and dtb updates with `update-board.sh` (network, reboot) | ok |
| PL bundle install, design trial-loaded and kept, **no reboot** | ok, ~0.5 s |
| design with a **128 KB** register window, then back to 64 KB, **no reboot** | ok: UIO window 0x10000 → 0x20000 → 0x10000 |
| bundle signed by a foreign key | refused: `self-signed certificate` |
| bundle with a flipped payload byte | refused: dm-verity read error, install failed |
| correctly signed bundle whose bitstream doesn't match its manifest | trial failed, good design reloaded, `rauc install` reports it |
| reset during a trial (fpgad frozen = watchdog thread stalled, as in a bus hang) | watchdog reset after 11 s, came back on the good design and reported it |

Notes from the hardware run:

- A tampered bundle whose artifact is already installed (same image hash in the
  signed manifest) "succeeds" without reading the payload — nothing tampered is used.
- An aborted install leaves a `.artifact-*.tmp` directory in `/data/rauc/pl`.
- A bundle that RAUC installed but fpgad rejected stays linked as
  `/data/rauc/pl/design`; fpgad boots from `/data/pl/good`, and the next bundle
  replaces the link.
- The fixed MAC made the DHCP address stable over most reboots, but the router still
  handed out a new one once. A DHCP reservation for `02:5a:4d:00:00:01` (or a static
  address) pins it; the OLED shows the current address meanwhile.
- The bus-hang case itself was reproduced by freezing fpgad (the watchdog thread
  stalls exactly as in a hung read); a deliberately hanging test bitstream would
  exercise the real bus.

### 1.11 Done when

- a PL bundle installs over the network and the new design runs without a reboot;
- a design with a **different register window** loads without a reboot;
- an unsigned or wrongly signed bundle is refused;
- a design that fails its checks rolls back by itself;
- a design that **hangs the bus** ends in a watchdog reset that comes back up on the
  previous design — no JTAG, no hands.

---

## Phase 2 — live app updates

Our software moves out of the rootfs into an artifact repository on `/data`:
`/data/rauc/apps/<name> -> <hash>/` (`trees`). The init scripts start the binaries
from there; RAUC's post-install handler restarts the changed services and checks them
(fpgad `ping`, fpga-web `/api/status`). On failure the previous version is linked back
and restarted. An app bundle declares the `REGMAP` versions it supports, so fpgad and
the PL can't drift apart.

## Phase 3 — A/B Linux, and no JTAG for the bootloader

**SD card layout** (one-time repartition with `reflash-over-ssh.sh`):

| partition | contents |
|---|---|
| `rootfs.0` / `rootfs.1` | ext4: rootfs **with its own kernel and dtb** in `/boot` — a slot is one atomic image |
| `data` | ext4: RAUC artifact repositories, `pl/good`, SSH host keys (no new host key after an update), settings |

**Bootloader in QSPI.** On SD the Zynq BootROM only reads `BOOT.BIN`; a broken one is
JTAG territory. In QSPI boot mode the BootROM searches the flash for a valid image, so:

- QSPI holds a **golden** `BOOT.BIN` (SPL + U-Boot) and an **update** copy at a higher
  offset; a bootloader update writes only the update copy, and if its header or
  checksum is bad the BootROM boots the golden one;
- the boot switch is set to **QSPI once**, by hand; after that the SD card holds only
  Linux slots and data.

**U-Boot**: environment in QSPI (redundant pair); a boot script with
`CONFIG_BOOTCOUNT_LIMIT` picks `rootfs.0`/`.1` (`BOOT_ORDER`, `BOOT_x_LEFT` — RAUC's
`bootloader=uboot` scheme). A new slot boots as a trial; a healthy system marks it
good (`rauc status mark-good` from an init script); three failed boots or a watchdog
reset fall back to the old slot.

**Network recovery**: if neither slot boots, U-Boot (from QSPI) fetches a recovery
image over TFTP/HTTP and boots it, so even a dead SD card is re-flashable over the
network. This replaces today's JTAG-driven TFTP reflash.

## Phase 4 — tools and web UI

- `update-board.sh <ip> pl|apps|os <bundle>`; with RAUC's network/streaming support a
  bundle can also be installed straight from an HTTP URL.
- An **Update** page in fpga-web: upload a bundle, see its signature and manifest,
  install. PL and app bundles take effect immediately; an OS bundle installs into the
  inactive slot and offers a reboot. The page shows the versions of all three layers
  and the active slot.
- fpga-web gets authentication before it can trigger installs (it has none today).

## Open items

- SD card size (sets the phase 3 partition sizes; 1 GB is plenty).
- Watchdog timeout (default 10 s in the DT) and whether an fpgad crash should reset the
  board or just restart fpgad (a supervisor would allow the latter).
- Production keys: the development CA lives on the build PC; a real deployment needs a
  key kept off it.
