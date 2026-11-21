# synthetic gyp host makefile
TOOLSET := host
TARGET := node_js2c
CFLAGS := -O3 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.5.sdk -miphoneos-version-min=14.0 -target arm64-apple-ios14.0
CXX.target := /work/bin/ios-cxx
CC.target := /work/bin/ios-cc
build: $(obj).host/x.o
	$(CXX.host) -c $(CFLAGS) $< -o $@
