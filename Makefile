TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Hello
Hello_FILES = hello.mm
Hello_CFLAGS = -fobjc-arc -std=c++17
Hello_FRAMEWORKS = UIKit Foundation
Hello_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk
