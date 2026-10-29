TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamRepro
VCamRepro_FILES = Tweak.m VCamSource.m
VCamRepro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
VCamRepro_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Camera SpringBoard" || true
