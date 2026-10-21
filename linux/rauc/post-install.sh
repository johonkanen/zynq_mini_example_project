#!/bin/sh
#
# RAUC post-install handler: runs after a bundle is installed, once the
# artifact links point at the new contents.
#
# A PL bundle installs /data/rauc/pl/design; fpgad then loads it as a trial
# (overlay + bitstream, checks SIGNATURE / BUILD_ID / REGMAP) and keeps it
# only if it passes, otherwise it reloads the last good design. A non-zero
# exit makes `rauc install` report the failure.
#
if [ -e /data/rauc/pl/design ]; then
	echo "post-install: activating the FPGA design from /data/rauc/pl/design"
	fpgactl activate /data/rauc/pl/design || exit 1
fi
exit 0
