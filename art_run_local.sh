#!/bin/bash
AOSP="/home/yanxi/loongson/aosp15.la"
AOSP_OUT_HOST="$AOSP/out/host/linux-x86"

BOOTCLASSPATH="${AOSP_OUT_HOST}/apex/com.android.art/javalib/core-oj.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/core-libart.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/okhttp.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/bouncycastle.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/apache-xml.jar:${AOSP_OUT_HOST}/apex/com.android.i18n/javalib/core-icu4j.jar:${AOSP_OUT_HOST}/apex/com.android.conscrypt/javalib/conscrypt.jar"

export ANDROID_BUILD_TOP="${AOSP}"
export ANDROID_HOST_OUT="${AOSP_OUT_HOST}"
export ANDROID_ROOT="${AOSP_OUT_HOST}"
export ANDROID_ART_ROOT="${AOSP_OUT_HOST}/apex/com.android.art"
export ANDROID_I18N_ROOT="${AOSP_OUT_HOST}/com.android.i18n"
export ANDROID_TZDATA_ROOT="${AOSP_OUT_HOST}/com.android.tzdata"
export ANDROID_DATA="${AOSP_OUT_HOST}/tmpdata"
export ICU_DATA_PATH="${ANDROID_I18N_ROOT}/etc/icu"
export LD_LIBRARY_PATH="${AOSP_OUT_HOST}/lib64:${AOSP_OUT_HOST}/lib"
export LD_USE_LOAD_BIAS=1
export PATH="${AOSP_OUT_HOST}/bin:${PATH}"

mkdir -p "${ANDROID_DATA}"/dalvik-cache/x86_64

"${AOSP_OUT_HOST}/bin/dalvikvm64" \
  -Xbootclasspath:"${BOOTCLASSPATH}" \
  -Xbootclasspath-locations:"${BOOTCLASSPATH}" \
  -cp scimark-dex.jar jnt.scimark2.commandline "$@"