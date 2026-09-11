TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BleepTube
BleepTube_FILES = Tweak.x
BleepTube_CFLAGS = -fobjc-arc -fblocks -Wno-error
BleepTube_FRAMEWORKS = UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
