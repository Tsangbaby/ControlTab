# ControlTab 1.0 原始二进制：iphoneos-arm64e，minos 15.0，链接 libroothide
# 下面按 roothide 方案配置；若改成 rootless/rootful，请同时修改 Tweak.xm 里的 jbroot 声明。

export THEOS_PACKAGE_SCHEME = roothide

TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ControlTab

ControlTab_FILES = Tweak.xm
# 原二进制为 MRR 编译（有显式 retain/release），此处保持一致，不要加 -fobjc-arc
ControlTab_CFLAGS = -fno-objc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
