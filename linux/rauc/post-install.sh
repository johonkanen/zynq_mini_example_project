#!/bin/sh
#
# RAUC post-install handler: runs after a bundle is installed, once the artifact
# links point at the new contents. A bundle can carry an app set, an FPGA design,
# or both; each activation is a trial that is kept only if it passes, and both
# skip a candidate that is already active.
#
# Apps first: a new fpgad that understands a new register map must be running
# before the design that needs it is loaded. A non-zero exit makes
# `rauc install` report the failure.
#
rc=0
if [ -e /data/rauc/apps/zynq-mini-apps ]; then
	appctl activate /data/rauc/apps/zynq-mini-apps || rc=1
fi
if [ $rc = 0 ] && [ -e /data/rauc/pl/design ]; then
	echo "post-install: activating the FPGA design from /data/rauc/pl/design"
	fpgactl activate /data/rauc/pl/design || rc=1
fi
exit $rc
