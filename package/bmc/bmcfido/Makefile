include $(TOPDIR)/rules.mk

PKG_NAME:=bmcfido
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)
# npm and npx of the build come from the Node.js built for the build host, not
# from whatever the build machine has installed.
PKG_BUILD_DEPENDS:=node/host

include $(INCLUDE_DIR)/package.mk

define Package/bmcfido
  SECTION:=webUI
  CATEGORY:=BMC
  TITLE:=BMC FIDO2 Server (Node.js)
  DEPENDS:=+node +libpthread
endef

define Package/bmcfido/description
  FIDO2 CAP Server for BMC, installed to /etc/bmcfido.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	echo "Compiling bmcfido scripts..."
	# Move to the source directory and build
	# --ignore-scripts: node-sass, a dependency only the style sheets need,
	# would build a native module here, and nothing of the server uses it.
	cd ./files/fido2cap-server && \
	npm install --ignore-scripts && \
	npm run build && \
	npx esbuild dist/index.js --bundle --platform=node --target=node18 --outfile=app.js
	echo "bmcfido scripts compiled successfully."
endef

define Build/InstallDev
	# Skip dev install
endef

define Package/bmcfido/install
	$(INSTALL_DIR) $(1)/etc/bmcfido
	
	# Copy the compiled app and assets
	$(CP) ./files/fido2cap-server/app.js $(1)/etc/bmcfido/
	$(CP) ./files/fido2cap-server/clientSessionStatus.js $(1)/etc/bmcfido/
	$(CP) ./files/fido2cap-server/.env $(1)/etc/bmcfido/
	$(CP) ./files/fido2cap-server/database.sqlite $(1)/etc/bmcfido/
	$(CP) ./files/fido2cap-server/sql-wasm.wasm $(1)/etc/bmcfido/

	# Copy public directory
	$(CP) ./files/fido2cap-server/public $(1)/etc/bmcfido/

	# Install config file
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/bmcfido.config $(1)/etc/config/bmcfido
	$(INSTALL_CONF) ./files/sfa.config $(1)/etc/config/sfa

	# Install init script
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/bmcfido.init $(1)/etc/init.d/bmcfido
	$(INSTALL_BIN) ./files/fido2cap-server/update_authorized_client.sh $(1)/etc/bmcfido/
	$(INSTALL_BIN) ./files/fido2cap-server/get_client_session_status.sh $(1)/etc/bmcfido/
endef

$(eval $(call BuildPackage,bmcfido))
