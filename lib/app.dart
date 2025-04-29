// lib/app.dart
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:async'; // Future 사용
import 'camera_screen.dart'; // 메인 화면 임포트

// 앱 시작 시 카메라 초기화를 담당하도록 StatefulWidget으로 변경 (예시)
class MyApp extends StatefulWidget {
  const MyApp({Key? key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Future<List<CameraDescription>>? _camerasFuture;

  @override
  void initState() {
    super.initState();
    // 앱 시작 시 카메라 목록 비동기 로드
    _camerasFuture = _initializeCameras();
  }

  Future<List<CameraDescription>> _initializeCameras() async {
    try {
      return await availableCameras();
    } on CameraException catch (e) {
      print('Error finding cameras: ${e.code}, ${e.description}');
      return []; // 오류 시 빈 리스트 반환
    } catch (e) {
      print('Unexpected error finding cameras: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Realtime Object Detection',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: FutureBuilder<List<CameraDescription>>(
        future: _camerasFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // 카메라 로딩 중
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          } else if (snapshot.hasError || snapshot.data == null || snapshot.data!.isEmpty) {
            // 오류 발생 또는 카메라 없음
            return const Scaffold(body: Center(child: Text('사용 가능한 카메라를 찾을 수 없습니다.')));
          } else {
            // 카메라 로드 완료, 메인 화면으로 이동 (카메라 목록 전달)
            return RealtimeObjectDetectionScreen(cameras: snapshot.data!);
          }
        },
      ),
    );
  }
}