################################################################################
#
# fpga-web
#
################################################################################

FPGA_WEB_VERSION = 1.0
FPGA_WEB_SITE = $(BR2_EXTERNAL_ZYNQMINI_PATH)/../fpga-web
FPGA_WEB_SITE_METHOD = local
FPGA_WEB_LICENSE = MIT
FPGA_WEB_DEPENDENCIES = fpgad civetweb

# fpga-web's /ws endpoint needs civetweb built with WebSocket support, which
# Buildroot's civetweb package leaves out. BR2_EXTERNAL makefiles are included
# after Buildroot's own packages and CIVETWEB_BUILD_CMDS expands this lazily,
# so appending here is enough. An already-built civetweb needs
# `make civetweb-dirclean` once (build-linux.sh does it).
CIVETWEB_CONF_OPTS += WITH_WEBSOCKET=1

define FPGA_WEB_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

# factory copy + app-exec link, as in fpgad.mk (doc/network_update.md, phase 2)
define FPGA_WEB_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/fpga-web $(TARGET_DIR)/usr/lib/zynq-mini/bin/fpga-web
	mkdir -p $(TARGET_DIR)/usr/bin
	ln -sf ../lib/zynq-mini/app-exec $(TARGET_DIR)/usr/bin/fpga-web
endef

define FPGA_WEB_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(FPGA_WEB_PKGDIR)/S97fpga-web $(TARGET_DIR)/etc/init.d/S97fpga-web
endef

$(eval $(generic-package))
