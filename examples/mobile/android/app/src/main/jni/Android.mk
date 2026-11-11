LOCAL_PATH := $(call my-dir)

# The library's headers, generated/ included, as `make liblogosdelivery-android-*`
# writes them next to the .so. TinyCBOR comes from the ffi package under
# nimbledeps/. `make android_example` passes both.
REPO_ROOT := $(LOCAL_PATH)/../../../../../../..
LOGOSDELIVERY_INCLUDE ?= $(REPO_ROOT)/build/android/$(TARGET_ARCH_ABI)
TINYCBOR_DIR ?= $(shell ls -dt $(REPO_ROOT)/nimbledeps/pkgs2/ffi-* | head -1)/ffi/codegen/templates/cpp/vendor

include $(CLEAR_VARS)

LOCAL_MODULE := logosdelivery
LOCAL_SRC_FILES := ../jniLibs/$(TARGET_ARCH_ABI)/liblogosdelivery.so

include $(PREBUILT_SHARED_LIBRARY)

include $(CLEAR_VARS)

# The generated binding encodes requests with TinyCBOR.
LOCAL_MODULE := tinycbor
LOCAL_SRC_FILES := $(addprefix $(TINYCBOR_DIR)/tinycbor/, \
	cborencoder.c cborencoder_close_container_checked.c \
	cborparser.c cborparser_dup_string.c cborerrorstrings.c)
LOCAL_CFLAGS := -std=gnu99 -O2

include $(BUILD_STATIC_LIBRARY)

include $(CLEAR_VARS)

LOCAL_SRC_FILES := waku_ffi.c
LOCAL_MODULE := waku_jni
LOCAL_C_INCLUDES := $(LOGOSDELIVERY_INCLUDE) $(TINYCBOR_DIR)
LOCAL_LDLIBS := -llog
LOCAL_SHARED_LIBRARIES := logosdelivery
LOCAL_STATIC_LIBRARIES := tinycbor

include $(BUILD_SHARED_LIBRARY)
