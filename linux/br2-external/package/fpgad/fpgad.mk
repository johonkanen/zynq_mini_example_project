################################################################################
#
# fpgad
#
################################################################################

FPGAD_VERSION = 1.0
FPGAD_SITE = $(BR2_EXTERNAL_ZYNQMINI_PATH)/../fpgad
FPGAD_SITE_METHOD = local
FPGAD_LICENSE = MIT
FPGAD_INSTALL_STAGING = YES

define FPGAD_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define FPGAD_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(@D)/fpgad_client.h $(STAGING_DIR)/usr/include/fpgad_client.h
	$(INSTALL) -D -m 0644 $(@D)/libfpgad-client.a $(STAGING_DIR)/usr/lib/libfpgad-client.a
endef

define FPGAD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/fpgad $(TARGET_DIR)/usr/sbin/fpgad
	$(INSTALL) -D -m 0755 $(@D)/fpgactl $(TARGET_DIR)/usr/bin/fpgactl
endef

define FPGAD_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(FPGAD_PKGDIR)/S96fpgad $(TARGET_DIR)/etc/init.d/S96fpgad
endef

$(eval $(generic-package))
