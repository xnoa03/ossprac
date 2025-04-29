// lib/logic/mlkit_logic.dart
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart'; // RootIsolateToken, BackgroundIsolateBinaryMessenger
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'dart:io'; // Platform

// ML Kit ObjectDetector 초기화 함수 (옵션 설정 포함)
ObjectDetector initializeObjectDetector() {
  print("Initializing ML Kit detector...");
  final options = ObjectDetectorOptions(
    mode: DetectionMode.stream,
    classifyObjects: true, // <<-- [네임태그] 분류 활성화
    multipleObjects: true, // <<-- [바운딩 박스] 다중 객체 활성화
  );
  return ObjectDetector(options: options);
}

// --- Isolate 실행 함수들 ---

// 객체 탐지 Isolate 진입점
@pragma('vm:entry-point')
void detectObjectsIsolateEntry(List<Object> args) {
  final SendPort mainSendPort = args[0] as SendPort;
  final RootIsolateToken rootIsolateToken = args[1] as RootIsolateToken;

  // 플랫폼 채널 초기화 (ML Kit 내부 사용)
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  final ReceivePort receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort); // 메인 스레드에 응답 포트 전송

  receivePort.listen((message) async { // 데이터 수신 대기
    if (message is List) {
      try {
        final Uint8List bytes = message[0];
        final int width = message[1];
        final int height = message[2];
        final InputImageRotation rotation = message[3];
        final int formatRaw = message[4];
        final int bytesPerRow = message[5];

        // 실제 탐지 로직 호출
        final List<DetectedObject> objects = await _detectObjectsImpl(
            bytes, width, height, rotation, formatRaw, bytesPerRow);
        mainSendPort.send(objects); // 결과 전송
      } catch (e, stacktrace) {
        print("****** Error in detectObjectsIsolateEntry listen: $e");
        print(stacktrace);
        mainSendPort.send(['Error from Detection Isolate', e.toString()]); // 오류 전송
      }
    }
  });
}

// 실제 객체 탐지 구현 (Isolate 내부)
Future<List<DetectedObject>> _detectObjectsImpl(
    Uint8List bytes, int width, int height, InputImageRotation rotation,
    int formatRaw, int bytesPerRow) async {
  // Isolate 내에서 탐지기 생성 및 사용
  final options = ObjectDetectorOptions(
    mode: DetectionMode.single,
    classifyObjects: true, // <<-- [네임태그] 분류 활성화
    multipleObjects: true, // <<-- [바운딩 박스] 다중 객체 활성화
  );
  final ObjectDetector objectDetector = ObjectDetector(options: options);

  final inputImage = InputImage.fromBytes(
    bytes: bytes,
    metadata: InputImageMetadata(
      size: Size(width.toDouble(), height.toDouble()),
      rotation: rotation,
      format: InputImageFormatValue.fromRawValue(formatRaw) ?? InputImageFormat.nv21,
      bytesPerRow: bytesPerRow,
    ),
  );

  try {
    final List<DetectedObject> objects = await objectDetector.processImage(inputImage);
    return objects; // <<-- [바운딩 박스][네임태그] 결과 반환
  } catch (e, stacktrace) {
    print("****** Error processing image in _detectObjectsImpl: $e");
    print(stacktrace);
    return <DetectedObject>[];
  } finally {
    await objectDetector.close(); // 리소스 해제
  }
}

// 이미지 회전 계산 Isolate 진입점
@pragma('vm:entry-point')
void getImageRotationIsolateEntry(SendPort sendPort) {
  final ReceivePort receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);

  receivePort.listen((message) { // 방향 정보 수신 대기
     if (message is List && message.length == 2) {
        try {
          final int sensorOrientation = message[0];
          final DeviceOrientation deviceOrientation = message[1];
          // 실제 회전 계산 로직 호출
          final InputImageRotation? rotation = _getImageRotationImpl(
              sensorOrientation, deviceOrientation);
          sendPort.send(rotation); // 계산 결과 전송
        } catch (e, stacktrace) {
          print("****** Error in getImageRotationIsolateEntry listen: $e");
          print(stacktrace);
          sendPort.send(['Error from Rotation Isolate', e.toString()]); // 오류 전송
        }
     }
  });
}

// 실제 이미지 회전 계산 (Isolate 내부)
InputImageRotation? _getImageRotationImpl(
    int sensorOrientation, DeviceOrientation deviceOrientation) {
  // 플랫폼별 계산 로직 (이전 코드와 동일)
   if (Platform.isIOS) {
     int deviceOrientationAngle = 0; switch (deviceOrientation) { case DeviceOrientation.portraitUp: deviceOrientationAngle = 0; break; case DeviceOrientation.landscapeLeft: deviceOrientationAngle = 90; break; case DeviceOrientation.portraitDown: deviceOrientationAngle = 180; break; case DeviceOrientation.landscapeRight: deviceOrientationAngle = 270; break; default: break; }
     var compensatedRotation = (sensorOrientation + deviceOrientationAngle) % 360;
     return _rotationIntToInputImageRotation(compensatedRotation);
  } else { // Android
     int deviceOrientationAngle = 0; switch (deviceOrientation) { case DeviceOrientation.portraitUp: deviceOrientationAngle = 0; break; case DeviceOrientation.landscapeLeft: deviceOrientationAngle = 90; break; case DeviceOrientation.portraitDown: deviceOrientationAngle = 180; break; case DeviceOrientation.landscapeRight: deviceOrientationAngle = 270; break; default: break; }
     var compensatedRotation = (sensorOrientation - deviceOrientationAngle + 360) % 360;
     return _rotationIntToInputImageRotation(compensatedRotation);
  }
}

// 회전 각도를 InputImageRotation enum으로 변환
InputImageRotation _rotationIntToInputImageRotation(int rotation) {
   switch (rotation) { case 0: return InputImageRotation.rotation0deg; case 90: return InputImageRotation.rotation90deg; case 180: return InputImageRotation.rotation180deg; case 270: return InputImageRotation.rotation270deg; default: return InputImageRotation.rotation0deg;}
}