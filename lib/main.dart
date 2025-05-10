import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'app.dart'; // MyApp 위젯을 포함하는 app.dart 파일을 임포트합니다.

Future<void> main() async {
  // Flutter 앱을 실행하기 전에 Flutter 엔진과 위젯 바인딩이 초기화되었는지 확인합니다.
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = []; // main 함수 내 지역 변수로 선언
  try {
    cameras = await availableCameras(); // 사용 가능한 카메라 목록 가져오기
    if (cameras.isNotEmpty) {
      print("${cameras.length}개의 카메라를 찾았습니다.");
    } else {
      print("사용 가능한 카메라가 없습니다.");
    }
  } on CameraException catch (e) {
    // 카메라를 가져오는 데 실패하면 오류를 기록합니다.
    print('카메라를 가져오는 중 오류 발생: ${e.code} ${e.description}');
  }

  // MyApp 위젯을 실행하고 카메라 목록을 전달합니다.
  // const 키워드를 제거하고 cameras 매개변수를 전달합니다.
  runApp(MyApp(cameras: cameras));
}