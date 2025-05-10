import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'camera_screen.dart'; // RealtimeObjectDetectionScreen 임포트

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  // 생성자: cameras 매개변수는 필수입니다.
  const MyApp({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '실시간 객체 탐지 앱',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: cameras.isEmpty
          ? Scaffold(
              appBar: AppBar(title: const Text('카메라 오류')),
              body: const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    '사용 가능한 카메라가 없습니다.\n앱 권한을 확인하거나 앱을 재시작해주세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.red),
                  ),
                ),
              ),
            )
          : RealtimeObjectDetectionScreen(cameras: cameras),
    );
  }
  // app.dart 파일 내에는 이 MyApp 클래스 정의 외에 다른 main() 함수나 runApp() 호출이 없어야 합니다.
}