TARGET = iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = twin
twin_FILES = il2cpp_kit.mm twin_esp.mm twin_aim.mm twin_backup.mm twin_unban.mm twin_shield.mm twin_ui.mm bypass.mm
twin_CFLAGS = -fobjc-arc -std=c++17 -O2
twin_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics Security CommonCrypto
twin_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk
