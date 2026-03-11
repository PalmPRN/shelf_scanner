# Shelf Scanner Prototype

This project demonstrates a complete Flutter prototype for a shelf scanning application. The app captures a long retail shelf without requiring manual button presses.

## Architecture

The system relies entirely on offline, local computation to fulfill the strict "no cloud services" requirement.

1. **Flutter Camera Image Stream**: The front-end renders a realtime preview, feeding YUV frames.
2. **Platform Channels**: `MethodChannel` bridges Flutter to the Native Kotlin wrapper, passing raw image bytes.
3. **OpenCV C++ (JNI)**: A compiled `native-lib.cpp` receives frames.
4. **Auto-Capture via ORB**: The C++ algorithm tracks horizontal movement. Once the camera translates by ~30% of the frame width, it automatically saves the frame to an in-memory buffer.
5. **Final Stitching**: When the user presses "Finish & Stitch", the `cv::Stitcher` pipeline automatically aligns and blends the captured panoramas.

## Provided Implementations

- `lib/scanner_screen.dart`: The Flutter side dealing with streams, UI guidance, and method channels.
- `android/app/src/main/kotlin/.../MainActivity.kt`: The Kotlin JNI wrapper bridging method channel commands.
- `android/app/src/main/cpp/native-lib.cpp`: The pure C++ code with OpenCV overlap detection and stitching.
- `android/app/src/main/cpp/CMakeLists.txt`: Build configurations to stitch OpenCV into the project.

## How to Compile & Run

### 1. Flutter Dependencies

Ensure your `pubspec.yaml` has the required dependencies:

```yaml
dependencies:
  flutter:
    sdk: flutter
  camera: ^0.10.5+5
  path_provider: ^2.1.1
```

### 2. Configure Android Permissions

In `android/app/src/main/AndroidManifest.xml`, make sure you add:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

### 3. Setup OpenCV Android SDK

To actually compile the C++ piece, you need to provide the OpenCV Android SDK locally.

1. Download OpenCV Android SDK from [opencv.org](https://opencv.org/releases/).
2. Extract the archive.
3. Move the enclosed `OpenCV-android-sdk/sdk` folder inside `android/app/src/main/cpp/opencv`.

### 4. Enable CMake in build.gradle

Modify your `android/app/build.gradle` inside the `android { ... }` block to include external native builds:

```gradle
android {
    ...
    defaultConfig {
        ...
        externalNativeBuild {
            cmake {
                cppFlags "-std=c++11 -frtti -fexceptions"
                arguments "-DANDROID_STL=c++_shared"
            }
        }
    }
    externalNativeBuild {
        cmake {
            path "src/main/cpp/CMakeLists.txt"
        }
    }
}
```

### 5. Running

Plug in a physical Android device and run:

```bash
flutter run
```
