#!/bin/sh
#
# RAUC post-install handler: runs after a bundle is installed, once the artifact
# links point at the new contents. A bundle can carry an app set, an FPGA design,
# or both; each activation is a trial that is kept only if it passes, and both
# skip a candidate that is already active.
#
# Only what *this* bundle carries is activated (its manifest.raucm, in the
# mounted bundle): the artifact links keep pointing at the last installed
# contents even after a trial rejected them, so an app bundle must not bring
# back an FPGA design that failed before.
#
# Apps first: a new fpgad that understands a new register map must be running
# before the design that needs it is loaded. A non-zero exit makes
# `rauc install` report the failure.
#
MANIFEST="$RAUC_BUNDLE_MOUNT_POINT/manifest.raucm"
carries() {    # carries apps|pl
	grep -q "^\[image\.$1/" "$MANIFEST" 2>/dev/null
}
[ -r "$MANIFEST" ] || { echo "post-install: no bundle manifest ($MANIFEST)"; exit 1; }

rc=0
if carries apps; then
	appctl activate /data/rauc/apps/zynq-mini-apps || rc=1
fi
if [ $rc = 0 ] && carries pl; then
	echo "post-install: activating the FPGA design from /data/rauc/pl/design"
	fpgactl activate /data/rauc/pl/design || rc=1
fi
exit $rc
