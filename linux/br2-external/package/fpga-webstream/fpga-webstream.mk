################################################################################
#
# fpga-webstream
#
################################################################################

FPGA_WEBSTREAM_VERSION = 1.0
FPGA_WEBSTREAM_SITE = $(BR2_EXTERNAL_ZYNQMINI_PATH)/../fpga-webstream
FPGA_WEBSTREAM_SITE_METHOD = local
FPGA_WEBSTREAM_LICENSE = MIT
FPGA_WEBSTREAM_DEPENDENCIES = civetweb

define FPGA_WEBSTREAM_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define FPGA_WEBSTREAM_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/fpga-webstream $(TARGET_DIR)/usr/bin/fpga-webstream
endef

define FPGA_WEBSTREAM_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(FPGA_WEBSTREAM_PKGDIR)/S97fpga-webstream \
		$(TARGET_DIR)/etc/init.d/S97fpga-webstream
endef

$(eval $(generic-package))
