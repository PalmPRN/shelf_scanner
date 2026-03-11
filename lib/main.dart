import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'scanner_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shelf Scanner',
      theme: ThemeData(brightness: Brightness.dark, primarySwatch: Colors.blue),
      home: ScannerScreen(cameras: cameras),
    );
  }
}
