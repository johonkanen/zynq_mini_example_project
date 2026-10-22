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

# The binaries are the image's factory copies in /usr/lib/zynq-mini/bin; the
# usual paths are links to app-exec, which runs the installed app set
# (/data/apps/good, from an app bundle) instead when there is one. appctl and
# S90apps manage those app sets (doc/network_update.md, phase 2).
FPGAD_APPS_DIR = $(BR2_EXTERNAL_ZYNQMINI_PATH)/../apps

define FPGAD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/fpgad $(TARGET_DIR)/usr/lib/zynq-mini/bin/fpgad
	$(INSTALL) -D -m 0755 $(@D)/fpgactl $(TARGET_DIR)/usr/lib/zynq-mini/bin/fpgactl
	$(INSTALL) -D -m 0755 $(@D)/oled-status $(TARGET_DIR)/usr/lib/zynq-mini/bin/oled-status
	$(INSTALL) -D -m 0755 $(FPGAD_APPS_DIR)/app-exec $(TARGET_DIR)/usr/lib/zynq-mini/app-exec
	$(INSTALL) -D -m 0755 $(FPGAD_APPS_DIR)/appctl $(TARGET_DIR)/usr/sbin/appctl
	mkdir -p $(TARGET_DIR)/usr/sbin $(TARGET_DIR)/usr/bin
	ln -sf ../lib/zynq-mini/app-exec $(TARGET_DIR)/usr/sbin/fpgad
	ln -sf ../lib/zynq-mini/app-exec $(TARGET_DIR)/usr/bin/fpgactl
	ln -sf ../lib/zynq-mini/app-exec $(TARGET_DIR)/usr/bin/oled-status
endef

define FPGAD_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(FPGAD_PKGDIR)/S96fpgad $(TARGET_DIR)/etc/init.d/S96fpgad
	$(INSTALL) -D -m 0755 $(FPGAD_PKGDIR)/S98oled-status $(TARGET_DIR)/etc/init.d/S98oled-status
	$(INSTALL) -D -m 0755 $(FPGAD_APPS_DIR)/S90apps $(TARGET_DIR)/etc/init.d/S90apps
endef

$(eval $(generic-package))
