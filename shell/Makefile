TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = DshGo
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DshGo
DshGo_FILES = main.swift
DshGo_FRAMEWORKS = UIKit WebKit
DshGo_CODESIGN_FLAGS = -S../build/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
