package com.example.shelf_scanner

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.shelf_scanner/opencv"

    // Load the native OpenCV C++ library
    init {
        try {
            System.loadLibrary("opencv_java4")
        } catch (e: UnsatisfiedLinkError) {
            e.printStackTrace()
        }
        System.loadLibrary("native-lib")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    startScanNative()
                    result.success(null)
                }
                "processFrame" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    val yRowStride = call.argument<Int>("yRowStride") ?: 0
                    val allowRight = call.argument<Boolean>("allowRight") ?: true
                    val allowDown = call.argument<Boolean>("allowDown") ?: true
                    val allowUp = call.argument<Boolean>("allowUp") ?: true
                    val gridX = call.argument<Int>("gridX") ?: 1
                    val gridY = call.argument<Int>("gridY") ?: 1
                    val forceCapture = call.argument<Boolean>("forceCapture") ?: false

                    if (bytes != null && width > 0 && height > 0) {
                        try {
                            // Call Native C++ method.
                            val resultData = processFrameNative(bytes, width, height, yRowStride, allowRight, allowDown, allowUp, gridX, gridY, forceCapture)
                            result.success(resultData.toList())
                        } catch (e: Exception) {
                            e.printStackTrace()
                            result.error("ERROR", "Failed to process frame natively", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENTS", "Invalid byte array or dimensions", null)
                    }
                }
                "stitchFrames" -> {
                    val outputPath = call.argument<String>("outputPath") ?: ""
                    Thread {
                        val finalPath = stitchFramesNative(outputPath)
                        activity.runOnUiThread {
                            if (finalPath.isNotEmpty()) {
                                result.success(finalPath)
                            } else {
                                result.success(null) // Failed, maybe not enough overlap
                            }
                        }
                    }.start()
                }
                "getCapturedFrames" -> {
                    val outputDir = call.argument<String>("outputDir") ?: ""
                    val resultString = getCapturedFramesNative(outputDir)
                    result.success(resultString)
                }
                else -> result.notImplemented()
            }
        }
    }

    // --- Native JNI Method Declarations ---
    external fun startScanNative()
    external fun processFrameNative(bytes: ByteArray, width: Int, height: Int, rowStride: Int, allowRight: Boolean, allowDown: Boolean, allowUp: Boolean, gridX: Int, gridY: Int, forceCapture: Boolean): DoubleArray
    external fun stitchFramesNative(outputPath: String): String
    external fun getCapturedFramesNative(outputDir: String): String
}
