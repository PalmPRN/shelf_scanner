import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:math' as math;

class ScannerScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const ScannerScreen({super.key, required this.cameras});

  @override
  _ScannerScreenState createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  late CameraController _controller;
  bool _isProcessingFrame = false;
  int _capturedCount = 0;
  bool _isScanning = false;
  bool _showFlash = false;
  double _translationX = 0.0;
  double _translationY = 0.0;
  double _overlapThreshold = 100.0;
  double _holdingProgress = 0.0;

  int _currentGridX = 1;
  int _currentGridY = 1;
  int? _maxGridY;

  CameraImage? _lastCameraImage;

  String _getExcelCoord(int col, int row) {
    if (col <= 0) return "?$row";
    String colName = "";
    int c = col;
    while (c > 0) {
      int mod = (c - 1) % 26;
      colName = String.fromCharCode(65 + mod) + colName;
      c = (c - mod) ~/ 26;
    }
    return "$colName$row";
  }

  bool get _allowRight {
    // If we haven't finished the first column, we don't know the height/maxGridY yet.
    // However, the user must be able to signal they are at the bottom of the shelf.
    // Moving Right in Col 1 effectively sets the height of the whole shelf.
    if (_currentGridX % 2 != 0) {
      // Odd column (DOWN): Allow Right only if maxGridY is discovered or user decides it's the bottom.
      if (_maxGridY == null) return true;
      return _currentGridY == _maxGridY;
    } else {
      // Even column (UP): Allow Right only when back at the top.
      return _currentGridY == 1;
    }
  }

  bool get _allowDown {
    if (_currentGridX % 2 == 0) return false; // even column goes up
    if (_maxGridY != null && _currentGridY >= _maxGridY!) return false;
    return true;
  }

  bool get _allowUp {
    if (_currentGridX % 2 != 0) return false; // odd column goes down
    if (_currentGridY <= 1) return false;
    return true;
  }

  // Platform channel communication to Native Android/iOS
  static const MethodChannel _channel = MethodChannel(
    'com.example.shelf_scanner/opencv',
  );

  @override
  void initState() {
    super.initState();
    // Initialize the camera
    _controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _startScan() async {
    // Clear Flutter's internal image memory cache to prevent "ghost" images
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    // Cleanup old temporary frame images from disk BEFORE starting
    final dir = await getApplicationDocumentsDirectory();
    try {
      final List<FileSystemEntity> oldFiles = dir.listSync();
      for (var file in oldFiles) {
        // More aggressive cleanup: delete any jpg file in the temp dir
        if (file.path.endsWith('.jpg')) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}

    setState(() {
      _isScanning = true;
      _capturedCount = 0;
      _currentGridX = 1;
      _currentGridY = 1;
      _maxGridY = null;
    });

    // Let Native code know we are starting a scan and clear cached frames
    await _channel.invokeMethod('startScan');

    // Start realtime image stream
    // Flutter camera image stream to platform channel communication
    _controller.startImageStream((CameraImage image) {
      _lastCameraImage = image;
      if (_isProcessingFrame)
        return; // Drop frame if native is busy processing overlap
      _isProcessingFrame = true;
      _processFrame(image);
    });
  }

  Future<void> _processFrame(
    CameraImage image, {
    bool forceCapture = false,
  }) async {
    try {
      final WriteBuffer allBytes = WriteBuffer();
      // Plane 0 is Y, Plane 1 is U/V interleaved
      allBytes.putUint8List(image.planes[0].bytes);
      if (image.planes.length > 1) {
        allBytes.putUint8List(image.planes[1].bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      // Platform channel communication: Send frame data to native module
      final List<dynamic>? resultData = await _channel
          .invokeMethod<List<dynamic>>('processFrame', {
            'bytes': bytes,
            'width': image.width,
            'height': image.height,
            'yRowStride': image.planes[0].bytesPerRow,
            'uvRowStride': image.planes.length > 1
                ? image.planes[1].bytesPerRow
                : 0,
            'uvPixelStride': image.planes.length > 1
                ? image.planes[1].bytesPerPixel
                : 0,
            'allowRight': _allowRight,
            'allowDown': _allowDown,
            'allowUp': _allowUp,
            'gridX': _currentGridX,
            'gridY': _currentGridY,
            'forceCapture': forceCapture,
          });

      if (resultData != null && resultData.length >= 5) {
        bool isCaptured = resultData[0] == 1.0;

        setState(() {
          _translationX = resultData[1] as double;
          _translationY = resultData[2] as double;
          _overlapThreshold = resultData[3] as double;
          if (resultData.length >= 6) {
            _holdingProgress = resultData[5] as double;
          }
        });

        if (isCaptured) {
          int captureDir = (resultData[4] as double).toInt();
          // Auto-capture triggered due to visual overlap detected natively
          setState(() {
            _capturedCount++;
            _showFlash = true;
            if (captureDir == 1) {
              // Right
              _currentGridX++;
              if (_maxGridY == null) {
                _maxGridY = _currentGridY;
              }
            } else if (captureDir == 2) {
              // Down
              _currentGridY++;
            } else if (captureDir == 3) {
              // Up
              _currentGridY--;
            }
          });

          // Provide physical feedback and visual cue
          HapticFeedback.lightImpact();

          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted) {
              setState(() {
                _showFlash = false;
              });
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Error processing frame: $e');
    } finally {
      // Free the lock for the next frame
      _isProcessingFrame = false;
    }
  }

  void _showAllCapturedImages() async {
    final directory = await getApplicationDocumentsDirectory();
    final String? result = await _channel.invokeMethod<String>(
      'getCapturedFrames',
      {'outputDir': directory.path},
    );

    if (result == null || result.isEmpty) return;

    final List<String> frameData = result.split(';');
    final List<Map<String, dynamic>> frames = frameData.map((s) {
      final parts = s.split(',');
      return {
        'row': int.parse(parts[0]),
        'col': int.parse(parts[1]),
        'path': parts[2],
      };
    }).toList();

    int maxCol = 1;
    for (var f in frames) {
      if (f['col'] > maxCol) maxCol = f['col'];
    }

    // Sort by Row then Column for a true horizontal Shelf/Excel layout
    // Row 1: A1, B1, C1 (Left to Right)
    // Row 2: A2, B2, C2
    frames.sort((a, b) {
      if (a['row'] != b['row']) return a['row'].compareTo(b['row']);
      return a['col'].compareTo(b['col']);
    });

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'All Captured Frames',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.only(bottom: 40),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    // Match the actual shelf width
                    crossAxisCount: maxCol > 1 ? maxCol : 2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.75, // Better for shelf photos
                  ),
                  itemCount: frames.length,
                  itemBuilder: (ctx, idx) {
                    final f = frames[idx];
                    return InkWell(
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (_) => Scaffold(
                            backgroundColor: Colors.black,
                            appBar: AppBar(
                              backgroundColor: Colors.transparent,
                              leading: IconButton(
                                icon: const Icon(
                                  Icons.arrow_back,
                                  color: Colors.white,
                                ),
                                onPressed: () => Navigator.pop(context),
                              ),
                              title: Text(
                                _getExcelCoord(f['col'], f['row']),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            body: Center(
                              child: InteractiveViewer(
                                child: Image.file(
                                  File(f['path']),
                                  key: ValueKey(f['path']),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(f['path']),
                                key: ValueKey(f['path']),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            left: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _getExcelCoord(f['col'], f['row']),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _stopScanAndStitch() async {
    setState(() => _isScanning = false);

    // Force one last capture of the current frame to ensure the final view is included!
    if (_lastCameraImage != null) {
      await _processFrame(_lastCameraImage!, forceCapture: true);
    }

    await _controller.stopImageStream();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.blueAccent.withOpacity(0.5)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                height: 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                  child: LinearProgressIndicator(
                    color: Colors.blueAccent,
                    backgroundColor: Colors.white10,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'AI STITCHING',
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Constructing shelf panorama...',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );

    // Provide the path where we want to save the final panorama image
    final directory = await getApplicationDocumentsDirectory();
    final outputPath =
        '${directory.path}/shelf_panorama_${DateTime.now().millisecondsSinceEpoch}.jpg';

    // Tell native code to execute OpenCV panoramic stitching
    final String? resultPath = await _channel.invokeMethod<String>(
      'stitchFrames',
      {'outputPath': outputPath},
    );

    // ignore: use_build_context_synchronously
    Navigator.of(context).pop();

    if (resultPath != null) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => Dialog(
          insetPadding: EdgeInsets.zero,
          child: Stack(
            children: [
              InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 5.0,
                child: Center(
                  child: Image.file(File(resultPath), fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 30,
                right: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 30),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              Positioned(
                bottom: 30,
                left: 20,
                right: 20,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _showAllCapturedImages(),
                      icon: const Icon(Icons.grid_view),
                      label: const Text('View All Images (Grid)'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 24,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 16,
                      ),
                      child: Text(
                        'Saved to: $resultPath',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stitching failed. Need more overlap.')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Shelf Scanner')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 1 / _controller.value.aspectRatio,
              child: CameraPreview(_controller),
            ),
          ),

          // Real-time viewfinder guidelines overlaid directly on screen
          if (_isScanning)
            Positioned.fill(
              child: CustomPaint(
                painter: ViewfinderPainter(
                  dx: _translationX,
                  dy: _translationY,
                  threshold: _overlapThreshold,
                  allowRight: _allowRight,
                  allowDown: _allowDown,
                  allowUp: _allowUp,
                  holdingProgress: _holdingProgress,
                ),
              ),
            ),

          // Basic UI guidance for scanning direction
          if (_isScanning)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Generate a dot for every captured frame
                    for (int i = 0; i < _capturedCount; i++)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6.0),
                        child: Icon(
                          Icons.circle,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    // The "Current/Next" tracker icon at the end
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6.0),
                      child: Icon(
                        Icons.radar,
                        color: Colors.greenAccent,
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Flash effect to let the user know a capture happened
          if (_showFlash)
            Positioned.fill(
              child: Container(color: Colors.white.withOpacity(0.6)),
            ),

          Positioned(
            bottom: 160,
            left: 16,
            right: 16,
            child: Text(
              _isScanning
                  ? 'Align the FLOATING BUBBLE with the CENTER CROSSHAIR.'
                  : 'Position the shelf in the center box and start.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(color: Colors.black, blurRadius: 4)],
              ),
            ),
          ),

          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Images: $_capturedCount  |  Grid: Col $_currentGridX, Row $_currentGridY',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: _isScanning
                  ? ElevatedButton.icon(
                      onPressed: _stopScanAndStitch,
                      icon: const Icon(Icons.stop),
                      label: const Text(
                        'Finish & Stitch',
                        style: TextStyle(fontSize: 18),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    )
                  : ElevatedButton.icon(
                      onPressed: _startScan,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text(
                        'Start Scanning',
                        style: TextStyle(fontSize: 18),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class ViewfinderPainter extends CustomPainter {
  final double dx;
  final double dy;
  final double threshold;
  final bool allowRight;
  final bool allowDown;
  final bool allowUp;
  final double holdingProgress;

  ViewfinderPainter({
    required this.dx,
    required this.dy,
    required this.threshold,
    required this.allowRight,
    required this.allowDown,
    required this.allowUp,
    required this.holdingProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (threshold <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    // Box dimension: Scale dynamically with screen resolution instead of fixed points.
    // Gives an 8% outer margin on all sides.
    final double paddingX = size.width * 0.08;
    final double paddingY = size.height * 0.08;
    final boxSize = Size(size.width - paddingX * 2, size.height - paddingY * 2);

    // Draw dark overlay outside the capture box to indicate "out of scope"
    final overlayPaint = Paint()
      ..color = Colors.black.withOpacity(0.7)
      ..style = PaintingStyle.fill;

    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final cutoutPath = Path()
      ..addRect(
        Rect.fromCenter(
          center: center,
          width: boxSize.width,
          height: boxSize.height,
        ),
      );

    final combinedPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      cutoutPath,
    );
    canvas.drawPath(combinedPath, overlayPaint);

    // Draw capture box border
    final boxBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRect(
      Rect.fromCenter(
        center: center,
        width: boxSize.width,
        height: boxSize.height,
      ),
      boxBorderPaint,
    );

    // 1. Center Crosshair (Fixed focal point)
    final crosshairPaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawCircle(center, 15, crosshairPaint);
    canvas.drawLine(
      center - const Offset(20, 0),
      center + const Offset(20, 0),
      crosshairPaint,
    );
    canvas.drawLine(
      center - const Offset(0, 20),
      center + const Offset(0, 20),
      crosshairPaint,
    );

    // 2. Define Target Displacement for next capture based on allowed direction
    Offset targetOffset = Offset.zero;
    if (allowDown)
      targetOffset = Offset(0, threshold);
    else if (allowUp)
      targetOffset = Offset(0, -threshold);
    else if (allowRight)
      targetOffset = Offset(threshold, 0);

    // Current displacement from last capture
    final Offset currentOffset = Offset(dx, dy);

    // Relative position of the "Next Capture Point" in screen space
    // Scale factor: move target bubble inside the capture box
    // 0.7 ratio = 70% of box size (increased for more visual distance)
    final double scale = boxSize.width * 0.7;
    final Offset bubblePos =
        center + (targetOffset - currentOffset) * (scale / threshold);

    // 3. Floating Target Bubble
    final bool isAligned =
        (targetOffset - currentOffset).distance <
        (threshold * 0.15); // Within 15% range
    final bubbleColor = isAligned ? Colors.greenAccent : Colors.yellowAccent;

    // Pulse effect for bubble
    final int millis = DateTime.now().millisecondsSinceEpoch;
    final double pulse = (math.sin(millis / 150) + 1) / 2;

    final bubblePaint = Paint()
      ..color = bubbleColor.withOpacity(0.5 + (pulse * 0.3))
      ..style = PaintingStyle.fill;

    final bubbleBorder = Paint()
      ..color = bubbleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // Draw path line to target
    canvas.drawLine(
      center,
      bubblePos,
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );

    canvas.drawCircle(bubblePos, 20, bubblePaint);
    canvas.drawCircle(bubblePos, 20, bubbleBorder);

    // 4. Holding Progress (inside the bubble)
    if (holdingProgress > 0.0) {
      final progressPaint = Paint()
        ..color = Colors.greenAccent
        ..style = PaintingStyle.fill;

      canvas.drawCircle(bubblePos, 20 * holdingProgress, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ViewfinderPainter oldDelegate) {
    return dx != oldDelegate.dx ||
        dy != oldDelegate.dy ||
        allowRight != oldDelegate.allowRight ||
        allowDown != oldDelegate.allowDown ||
        allowUp != oldDelegate.allowUp ||
        holdingProgress != oldDelegate.holdingProgress;
  }
}
