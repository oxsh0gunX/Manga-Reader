#!/bin/bash
# REAL Flutter PDF Reader, packaged MANUALLY without Gradle (same route as Aura).
# flutter assemble (Dart AOT per ABI + flutter_assets) -> javac host ->
# aapt2 link -> d8 dex -> add libs/assets -> zipalign -> apksigner.
set -e
# Locations are overridable so the script is not tied to one machine:
# WORKSPACE, JAVA_HOME, FLUTTER_BIN, ANDROID_SDK, PROJ, KEYSTORE.
WS="${WORKSPACE:-$HOME/workspace}"
FLUTTER_BIN="${FLUTTER_BIN:-$WS/flutter/bin}"
KEYSTORE="${KEYSTORE:-$WS/debug.keystore}"
cd "$WS"
# JDK and Android SDK live in $HOME, not in the workspace (the original
# script used ~/jdk17 and ~/Android/Sdk). Use an explicitly provided
# JAVA_HOME only if it actually contains javac; otherwise fall back.
if [ ! -x "${JAVA_HOME:-}/bin/javac" ]; then JAVA_HOME="$HOME/jdk17"; fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$FLUTTER_BIN:$PATH"
export ANDROID_HOME="${ANDROID_SDK:-$HOME/Android/Sdk}"
AAPT=$ANDROID_HOME/build-tools/34.0.0/aapt2
D8=$ANDROID_HOME/build-tools/34.0.0/d8
ZIPALIGN=$ANDROID_HOME/build-tools/34.0.0/zipalign
APKSIGNER=$ANDROID_HOME/build-tools/34.0.0/apksigner
PLATFORM=$ANDROID_HOME/platforms/android-34/android.jar
PROJ="${PROJ:-$WS/flutter-pdfreader}"
MANUAL=$PROJ/manual
FLUTTER_JAR=$WS/flutter-proof/filtered/flutter_embedding_release.jar

echo "=== flutter assemble arm64 + arm (release) ==="
cd $PROJ
flutter assemble -o build/manual-arm64 -d BuildMode=release -d TargetPlatform=android-arm64 -d TargetFile=lib/main.dart -d TrackWidgetCreation=false -d IconTreeShakerFlag=true android_aot_bundle_release_android-arm64
flutter assemble -o build/manual-arm -d BuildMode=release -d TargetPlatform=android-arm -d TargetFile=lib/main.dart -d TrackWidgetCreation=false -d IconTreeShakerFlag=true android_aot_bundle_release_android-arm
cd "$WS"

echo "=== stage libs + assets ==="
rm -rf $PROJ/build/manual-apk $PROJ/stage
mkdir -p $PROJ/build/manual-apk/compiled_res $PROJ/build/manual-apk/dex $PROJ/build/manual-apk/classes $PROJ/stage/lib/arm64-v8a $PROJ/stage/lib/armeabi-v7a $PROJ/stage/assets
cp $PROJ/build/manual-arm64/arm64-v8a/app.so $PROJ/stage/lib/arm64-v8a/libapp.so
cp $PROJ/build/manual-arm/armeabi-v7a/app.so $PROJ/stage/lib/armeabi-v7a/libapp.so
rm -rf /tmp/flib64 /tmp/flib32
mkdir -p /tmp/flib64 /tmp/flib32
cd $WS/flutter-artifacts
unzip -o -q arm64_v8a_release.jar lib/arm64-v8a/libflutter.so -d /tmp/flib64
unzip -o -q armeabi_v7a_release.jar lib/armeabi-v7a/libflutter.so -d /tmp/flib32
cd "$WS"
cp /tmp/flib64/lib/arm64-v8a/libflutter.so $PROJ/stage/lib/arm64-v8a/
cp /tmp/flib32/lib/armeabi-v7a/libflutter.so $PROJ/stage/lib/armeabi-v7a/
cp -r $PROJ/build/manual-arm64/flutter_assets $PROJ/stage/assets/flutter_assets
cp $FLUTTER_BIN/cache/artifacts/engine/linux-x64/icudtl.dat $PROJ/stage/assets/icudtl.dat

echo "=== javac host (MainActivity.java) ==="
javac -cp "$PLATFORM:$FLUTTER_JAR:$WS/flutter-proof/filtered/annotation-1.8.0.jar:$WS/m2/v6/filtered/lifecycle-common-2.6.1.jar:$WS/m2/v6/filtered/lifecycle-runtime-2.6.1.jar" \
  -d $PROJ/build/manual-apk/classes \
  $PROJ/android/app/src/main/java/com/example/pdfreader/MainActivity.java
cd $PROJ/build/manual-apk/classes && jar cf ../host-classes.jar com && cd "$WS"

echo "=== aapt2 compile + link ==="
$AAPT compile --dir $MANUAL/res -o $PROJ/build/manual-apk/compiled_res/res.zip
$AAPT link -o $PROJ/build/manual-apk/app.unaligned.apk -I $PLATFORM --manifest $MANUAL/AndroidManifest.xml $PROJ/build/manual-apk/compiled_res/res.zip --auto-add-overlay --min-sdk-version 26 --target-sdk-version 34

echo "=== d8 dex (host + flutter embedding + androidx runtime deps) ==="
$D8 --output $PROJ/build/manual-apk/dex --lib $PLATFORM \
  $PROJ/build/manual-apk/host-classes.jar \
  $WS/flutter-proof/filtered/flutter_embedding_release.jar \
  $WS/flutter-proof/filtered/core.jar \
  $WS/flutter-proof/filtered/activity.jar \
  $WS/flutter-proof/filtered/fragment.jar \
  $WS/flutter-proof/filtered/savedstate.jar \
  $WS/m2/v6/filtered/lifecycle-common-2.6.1.jar \
  $WS/m2/v6/filtered/lifecycle-runtime-2.6.1.jar \
  $WS/m2/v6/filtered/arch-core-common-2.2.0.jar \
  $WS/m2/v6/filtered/arch-core-runtime-2.2.0.jar \
  $WS/m2/v6/filtered/collection-1.0.0.jar \
  $WS/m2/v6/filtered/tracing-1.0.0.jar \
  $WS/flutter-proof/filtered/annotation-1.8.0.jar \
  $WS/flutter-proof/filtered/window.jar \
  $WS/flutter-proof/filtered/window-java.jar \
  $WS/flutter-proof/filtered-kotlin/kotlin-stdlib.jar \
  $WS/flutter-proof/filtered-kotlin/kotlinx-coroutines-core-jvm-1.7.3.jar \
  $WS/flutter-proof/filtered-kotlin/kotlinx-coroutines-android-1.7.3.jar \
  $WS/flutter-proof/filtered-kotlin/atomicfu-jvm-0.22.0.jar \
  $WS/flutter-proof/lifecycle-process/lifecycle-process-2.6.1.jar \
  $WS/m2/v6/filtered/interpolator-1.0.0.jar \
  $WS/flutter-proof/jetbrains-annotations/annotations-13.0.jar
ls -lh $PROJ/build/manual-apk/dex/

echo "=== add dex + libs + assets, align, sign ==="
cd $PROJ/build/manual-apk
for f in dex/*.dex; do zip -j app.unaligned.apk "$f" >/dev/null; done
cd $PROJ/stage && zip -r $PROJ/build/manual-apk/app.unaligned.apk assets lib >/dev/null
cd "$WS"
$ZIPALIGN -f -p 4 $PROJ/build/manual-apk/app.unaligned.apk $PROJ/build/manual-apk/app.aligned.apk
$APKSIGNER sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android --out $WS/PDFReader-v222.apk $PROJ/build/manual-apk/app.aligned.apk
$APKSIGNER verify $WS/PDFReader-v222.apk
ls -lh $WS/PDFReader-v222.apk
echo "PDF READER V2.2.2 DONE"
