include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Easy QoS
LUCI_DEPENDS:=+tc +kmod-sched-core +kmod-ifb +iptables-mod-ipopt +iptables-mod-conntrack-extra +iptables-mod-u32 +iptables-mod-iprange +ip6tables @!PACKAGE_luci-app-eqos

PKG_MAINTAINER:=Jianhui Zhao <jianhuizhao329@gmail.com>
PKG_NAME:=luci-app-eqos-mtk

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
