// lib/main.dart
import 'package:flutter/material.dart';
import 'app.dart'; // MyApp 위젯 임포트

void main() {
  // Flutter 엔진 바인딩 초기화
  WidgetsFlutterBinding.ensureInitialized();
  // 앱 실행 (MyApp 위젯 사용)
  runApp(const MyApp());
}