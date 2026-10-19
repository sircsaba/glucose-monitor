"""Adjusts the Android and iOS project files that `flutter create` generates.

Usage:  python3 scripts/patch_platforms.py android|ios
Uses the APP_NAME and BUNDLE_ID environment variables.
"""
import os
import plistlib
import re
import shutil
import sys

APP_NAME = os.environ.get('APP_NAME') or 'Glucose Monitor'
BUNDLE_ID = os.environ.get('BUNDLE_ID') or 'com.monitorglucose.app'


def patch_android():
    man = 'android/app/src/main/AndroidManifest.xml'
    with open(man) as f:
        text = f.read()
    perms = [
        'android.permission.INTERNET',
        'android.permission.WAKE_LOCK',
        'android.permission.VIBRATE',
        'android.permission.RECEIVE_BOOT_COMPLETED',
    ]
    add = ''.join(f'<uses-permission android:name="{p}"/>\n    ' for p in perms if p not in text)
    if add:
        text = text.replace('<application', add + '<application', 1)
    text = re.sub(r'android:label="[^"]*"', f'android:label="{APP_NAME}"', text, count=1)
    # Home-screen widget with the latest glucose (native/android).
    if 'BgWidget' not in text:
        receiver = '''<receiver android:name=".BgWidget" android:exported="false" android:label="Glucose">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
            <meta-data android:name="android.appwidget.provider" android:resource="@xml/bg_widget_info"/>
        </receiver>
    '''
        text = text.replace('</application>', receiver + '</application>', 1)
    with open(man, 'w') as f:
        f.write(text)
    main_act = None
    for root, _, files in os.walk('android/app/src/main'):
        for n in files:
            if n in ('MainActivity.kt', 'MainActivity.java'):
                main_act = os.path.join(root, n)
    if main_act and main_act.endswith('.kt'):
        # The phone lock prompt (local_auth) needs a FlutterFragmentActivity.
        with open(main_act) as f:
            ma = f.read()
        if 'FlutterFragmentActivity' not in ma:
            ma = ma.replace('import io.flutter.embedding.android.FlutterActivity', 'import io.flutter.embedding.android.FlutterFragmentActivity')
            ma = ma.replace(': FlutterActivity()', ': FlutterFragmentActivity()')
            with open(main_act, 'w') as f:
                f.write(ma)
    if main_act:
        with open(main_act) as f:
            pkg = re.search(r'^package\s+([\w.]+)', f.read(), re.M).group(1)
        with open('native/android/BgWidget.kt') as f:
            kt = f.read().replace('PACKAGE_NAME', pkg, 1)
        with open(os.path.join(os.path.dirname(main_act), 'BgWidget.kt'), 'w') as f:
            f.write(kt)
        for sub in ('layout', 'xml', 'drawable'):
            dst = f'android/app/src/main/res/{sub}'
            os.makedirs(dst, exist_ok=True)
            for n in os.listdir(f'native/android/res/{sub}'):
                shutil.copy(f'native/android/res/{sub}/{n}', dst)

    # Release builds are shrunk by R8, which removed methods the plugins call
    # (shared_preferences: settings could not be read, the app stayed on the
    # start screen). Keep the plugin classes and Kotlin coroutines.
    with open('android/app/proguard-rules.pro', 'a') as f:
        f.write('''
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class dev.fluttercommunity.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class net.nfet.flutter.printing.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlin.** { *; }
-dontwarn kotlinx.coroutines.**
''')

    for gradle in ['android/app/build.gradle.kts', 'android/app/build.gradle']:
        if not os.path.exists(gradle):
            continue
        with open(gradle) as f:
            g = f.read()
        g = re.sub(r'applicationId\s*=\s*"[^"]*"', f'applicationId = "{BUNDLE_ID}"', g)
        # A permanent signing key (GitHub secrets ANDROID_KEYSTORE_BASE64 and
        # ANDROID_KEYSTORE_PASSWORD), so a new APK installs over the old one.
        # Without it the APK is signed with a throw-away key: uninstall first.
        ks = os.environ.get('GM_KEYSTORE', '')
        pw = os.environ.get('GM_KEYSTORE_PASSWORD', '')
        if ks and pw and os.path.exists(ks) and 'create("upload")' not in g:
            if gradle.endswith('.kts'):
                block = ('    signingConfigs {\n        create("upload") {\n'
                         f'            storeFile = file("{ks}")\n            storePassword = "{pw}"\n'
                         f'            keyAlias = "glucosemonitor"\n            keyPassword = "{pw}"\n        }}\n    }}\n')
                g = re.sub(r'(\n\s*buildTypes\s*\{)', '\n' + block.replace('\\', '\\\\') + r'\1', g, count=1)
                g = g.replace('signingConfigs.getByName("debug")', 'signingConfigs.getByName("upload")')
            else:
                block = ('    signingConfigs {\n        upload {\n'
                         f"            storeFile file('{ks}')\n            storePassword '{pw}'\n"
                         f"            keyAlias 'glucosemonitor'\n            keyPassword '{pw}'\n        }}\n    }}\n")
                g = re.sub(r'(\n\s*buildTypes\s*\{)', '\n' + block + r'\1', g, count=1)
                g = g.replace('signingConfigs.debug', 'signingConfigs.upload')
            print('Android: signed with your permanent key')
        elif not ks:
            print('Android: no ANDROID_KEYSTORE_BASE64 secret, signed with a throw-away key')
        # No shrinking at all: R8 kept removing Kotlin classes the plugins need.
        if gradle.endswith('.kts') and 'isMinifyEnabled' not in g:
            g = re.sub(r'(buildTypes\s*\{\s*release\s*\{)', r'\1\n            isMinifyEnabled = false\n            isShrinkResources = false', g, count=1)
        elif not gradle.endswith('.kts') and 'minifyEnabled' not in g:
            g = re.sub(r'(buildTypes\s*\{\s*release\s*\{)', r'\1\n            minifyEnabled false\n            shrinkResources false', g, count=1)
        g = re.sub(r'applicationId\s+"[^"]*"', f'applicationId "{BUNDLE_ID}"', g)
        with open(gradle, 'w') as f:
            f.write(g)
    print('Android patched:', APP_NAME, BUNDLE_ID)


def patch_ios():
    plist_path = 'ios/Runner/Info.plist'
    with open(plist_path, 'rb') as f:
        p = plistlib.load(f)
    p['CFBundleDisplayName'] = APP_NAME
    p['CFBundleName'] = APP_NAME[:15]
    p['ITSAppUsesNonExemptEncryption'] = False
    p['UIApplicationSupportsIndirectInputEvents'] = True
    # Glucose Monitor Plus reads Loop's one-time password QR code from a photo.
    p['NSCameraUsageDescription'] = "Take a photo of Loop's one-time password QR code (remote commands)."
    p['NSPhotoLibraryUsageDescription'] = "Choose a screenshot of Loop's one-time password QR code (remote commands)."
    # The phone's lock (Face ID or passcode) confirms commands sent to Loop.
    p['NSFaceIDUsageDescription'] = "Confirm commands sent to Loop (carbs, bolus, overrides) with Face ID or your passcode."
    with open(plist_path, 'wb') as f:
        plistlib.dump(p, f)

    proj = 'ios/Runner.xcodeproj/project.pbxproj'
    with open(proj) as f:
        x = f.read()
    # Tests target first, then the app itself.
    x = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]*\.RunnerTests;', f'PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}.RunnerTests;', x)
    x = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = (?![^;]*RunnerTests)[^;]*;', f'PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};', x)
    with open(proj, 'w') as f:
        f.write(x)

    podfile = 'ios/Podfile'
    if os.path.exists(podfile):
        with open(podfile) as f:
            pod = f.read()
        pod = re.sub(r"^#?\s*platform :ios, '[^']*'", "platform :ios, '13.0'", pod, count=1, flags=re.M)
        with open(podfile, 'w') as f:
            f.write(pod)
    print('iOS patched:', APP_NAME, BUNDLE_ID)


if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else ''
    if which in ('android', 'all'):
        patch_android()
    if which in ('ios', 'all'):
        patch_ios()
