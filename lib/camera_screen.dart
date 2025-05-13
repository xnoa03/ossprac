// lib/camera_screen.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data'; // Uint8List
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart'; // DeviceOrientation, RootIsolateToken
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
// >>> 변경/추가 >>>
import 'logic/mlkit_logic.dart'; // ML Kit 로직 임포트
// >>> 변경/추가 >>>
import 'ui/object_painter.dart'; // 메인 Painter 임포트
// >>> 변경/추가 >>>
import 'dart:io'; // Platform 사용 위해 임포트

// >>> 변경/추가 >>> // Isolate에 데이터를 전달하기 위한 간단한 홀더 클래스
// >>> 변경/추가 >>>
class IsolateDataHolder {
// >>> 변경/추가 >>>
  final SendPort mainSendPort;
// >>> 변경/추가 >>>
  final RootIsolateToken? rootIsolateToken; // ML Kit은 RootIsolateToken 필요
// >>> 변경/추가 >>>

// >>> 변경/추가 >>>
  IsolateDataHolder(this.mainSendPort, this.rootIsolateToken);
// >>> 변경/추가 >>>
}


class RealtimeObjectDetectionScreen extends StatefulWidget {
  final List<CameraDescription> cameras; // 카메라 목록 전달받음
  const RealtimeObjectDetectionScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  _RealtimeObjectDetectionScreenState createState() =>
      _RealtimeObjectDetectionScreenState();
}

class _RealtimeObjectDetectionScreenState
    extends State<RealtimeObjectDetectionScreen> {
  CameraController? _cameraController;
  int _cameraIndex = 0;
  bool _isCameraInitialized = false;
  bool _isBusy = false; // 이미지 처리 중복 방지 플래그
// >>> 변경/추가 >>> // 항상 이 리스트를 Painter에 전달 (내용이 0 또는 1개 객체) - 주석 내용 변경
  List<DetectedObject> _detectedObjects = [];
  InputImageRotation? _imageRotation; // Painter에 전달될 최종 회전 값
  late ObjectDetector _objectDetector;
  Size? _lastImageSize; // ML Kit이 처리한 이미지의 크기

  // Isolate 관련
  Isolate? _objectDetectionIsolate;
  Isolate? _imageRotationIsolate;
  late ReceivePort _objectDetectionReceivePort;
  late ReceivePort _imageRotationReceivePort;
  SendPort? _objectDetectionIsolateSendPort;
  SendPort? _imageRotationIsolateSendPort;
  StreamSubscription? _objectDetectionSubscription;
  StreamSubscription? _imageRotationSubscription;

  // Isolate 작업 대기 상태 플래그
  bool _isWaitingForRotation = false;
  bool _isWaitingForDetection = false;

  // Isolate 간 데이터 전달을 위한 임시 저장 변수
  InputImageRotation? _lastCalculatedRotation; // 회전 Isolate에서 계산된 값
  Uint8List? _pendingImageDataBytes;
  int? _pendingImageDataWidth;
  int? _pendingImageDataHeight;
  int? _pendingImageDataFormatRaw;
  int? _pendingImageDataBytesPerRow;

  @override
  void initState() {
    super.initState();
// >>> 변경/추가 >>>
    print("RealtimeObjectDetectionScreen: initState called"); // 디버그 로그
// >>> 변경/추가 >>> // 외부 파일 함수 호출로 변경
    _objectDetector = initializeObjectDetector();

    _spawnIsolates().then((_) {
      if (widget.cameras.isNotEmpty) {
        _initializeCamera(widget.cameras[0]); // 카메라 초기화
      } else {
// >>> 변경/추가 >>> // 사용 가능 카메라 없을 시 처리 로직 추가
// >>> 변경/추가 >>>
        print("****** No cameras available!");
// >>> 변경/추가 >>>
        if (mounted) {
// >>> 변경/추가 >>>
          ScaffoldMessenger.of(context).showSnackBar(
// >>> 변경/추가 >>>
            const SnackBar(content: Text('사용 가능한 카메라가 없습니다.')),
// >>> 변경/추가 >>>
          );
// >>> 변경/추가 >>>
        }
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>> // Isolate 생성 또는 카메라 초기화 에러 처리 강화
    }).catchError((e, stacktrace) {
// >>> 변경/추가 >>>
      print("****** initState: Error spawning isolates or initializing camera: $e");
// >>> 변경/추가 >>>
      print(stacktrace);
// >>> 변경/추가 >>>
      if (mounted) {
// >>> 변경/추가 >>>
        ScaffoldMessenger.of(context).showSnackBar(
// >>> 변경/추가 >>>
          SnackBar(content: Text('초기화 중 오류 발생: $e')),
// >>> 변경/추가 >>>
        );
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>>
    });
  }

  @override
  void dispose() {
// >>> 변경/추가 >>>
    print("RealtimeObjectDetectionScreen: dispose called"); // 디버그 로그
// >>> 변경/추가 >>> // 스트림 먼저 중지하도록 순서 명확화
    _stopCameraStream();
    _objectDetectionSubscription?.cancel();
    _imageRotationSubscription?.cancel();
    _killIsolates(); // Isolate 종료
// >>> 변경/추가 >>> // CameraController dispose 결과 로깅 추가
    _cameraController?.dispose().then((_) {
// >>> 변경/추가 >>>
      print("CameraController disposed");
// >>> 변경/추가 >>>
    }).catchError((e) {
// >>> 변경/추가 >>>
      print("Error disposing camera controller: $e");
// >>> 변경/추가 >>>
    });
// >>> 변경/추가 >>> // ObjectDetector close 결과 로깅 추가
    _objectDetector.close().then((_) {
// >>> 변경/추가 >>>
      print("ObjectDetector closed");
// >>> 변경/추가 >>>
    }).catchError((e){
// >>> 변경/추가 >>>
      print("Error closing object detector: $e");
// >>> 변경/추가 >>>
    });
    super.dispose();
  }

  Future<void> _spawnIsolates() async {
// >>> 변경/추가 >>>
    print("Spawning Isolates..."); // 디버그 로그
    final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;

// >>> 변경/추가 >>> // RootIsolateToken null 체크 추가
// >>> 변경/추가 >>>
    if (rootIsolateToken == null) {
// >>> 변경/추가 >>>
      print("****** RootIsolateToken is null. ML Kit in Isolate might not work.");
// >>> 변경/추가 >>>
      return;
// >>> 변경/추가 >>>
    }

    _objectDetectionReceivePort = ReceivePort();
    _objectDetectionIsolate = await Isolate.spawn(
      detectObjectsIsolateEntry,
// >>> 변경/추가 >>> // IsolateDataHolder 사용하도록 변경
      IsolateDataHolder(_objectDetectionReceivePort.sendPort, rootIsolateToken),
      onError: _objectDetectionReceivePort.sendPort,
      onExit: _objectDetectionReceivePort.sendPort,
// >>> 변경/추가 >>> // Isolate 이름 지정
      debugName: "ObjectDetectionIsolate"
    );
    _objectDetectionSubscription =
        _objectDetectionReceivePort.listen(_handleDetectionResult);
// >>> 변경/추가 >>>
    print("Object Detection Isolate spawned and listener attached."); // 디버그 로그

    _imageRotationReceivePort = ReceivePort();
    _imageRotationIsolate = await Isolate.spawn(
      getImageRotationIsolateEntry,
// >>> 변경/추가 >>> // RootIsolateToken 불필요하여 제거
      _imageRotationReceivePort.sendPort,
      onError: _imageRotationReceivePort.sendPort,
      onExit: _imageRotationReceivePort.sendPort,
// >>> 변경/추가 >>> // Isolate 이름 지정
      debugName: "ImageRotationIsolate"
    );
    _imageRotationSubscription =
        _imageRotationReceivePort.listen(_handleRotationResult);
// >>> 변경/추가 >>>
    print("Image Rotation Isolate spawned and listener attached."); // 디버그 로그

    // --- 제거됨 ---
    // 이전 코드의 Completer와 Future.wait 로직 (동기화 문제 있었음)
    /*
    Completer<void> rotationPortCompleter = Completer();
    Completer<void> detectionPortCompleter = Completer();
    ...
    try {
      await Future.wait([
        rotationPortCompleter.future.timeout(const Duration(seconds: 5)),
        detectionPortCompleter.future.timeout(const Duration(seconds: 5)),
      ]);
    } catch (e) {
      _killIsolates();
      throw e;
    }
    */
  }

  void _killIsolates() {
// >>> 변경/추가 >>>
    print("Killing Isolates..."); // 디버그 로그
// >>> 변경/추가 >>> // Isolate kill 시도 시 에러 핸들링 추가
    try {
      _objectDetectionIsolate?.kill(priority: Isolate.immediate);
// >>> 변경/추가 >>>
      print("Object Detection Isolate kill signal sent."); // 디버그 로그
// >>> 변경/추가 >>>
    } catch (e) {
// >>> 변경/추가 >>>
      print("Error killing object detection isolate: $e");
// >>> 변경/추가 >>>
    }
// >>> 변경/추가 >>> // Isolate kill 시도 시 에러 핸들링 추가
    try {
      _imageRotationIsolate?.kill(priority: Isolate.immediate);
// >>> 변경/추가 >>>
      print("Image Rotation Isolate kill signal sent."); // 디버그 로그
// >>> 변경/추가 >>>
    } catch (e) {
// >>> 변경/추가 >>>
      print("Error killing image rotation isolate: $e");
// >>> 변경/추가 >>>
    }
    _objectDetectionIsolate = null;
    _imageRotationIsolate = null;
    _objectDetectionIsolateSendPort = null;
    _imageRotationIsolateSendPort = null;
  }

  void _handleDetectionResult(dynamic message) {
// >>> 변경/추가 >>>
    if (!mounted) return; // 위젯 unmount 시 처리 중단

    if (_objectDetectionIsolateSendPort == null && message is SendPort) {
// >>> 변경/추가 >>>
      print("Object Detection Isolate SendPort received via message."); // 디버그 로그
      _objectDetectionIsolateSendPort = message;
    } else if (message is List<DetectedObject>) {
// >>> 변경/추가 >>> // 가장 큰 바운딩 박스를 가진 객체 1개만 선택하는 로직 추가
// >>> 변경/추가 >>>
      List<DetectedObject> objectsToShow = [];
// >>> 변경/추가 >>>
      if (message.isNotEmpty) {
// >>> 변경/추가 >>>
        DetectedObject closestObject = message.reduce((curr, next) {
// >>> 변경/추가 >>>
          final double areaCurr = curr.boundingBox.width * curr.boundingBox.height;
// >>> 변경/추가 >>>
          final double areaNext = next.boundingBox.width * next.boundingBox.height;
// >>> 변경/추가 >>>
          return areaCurr > areaNext ? curr : next;
// >>> 변경/추가 >>>
        });
// >>> 변경/추가 >>>
        objectsToShow.add(closestObject);
// >>> 변경/추가 >>>
      }

      _isWaitingForDetection = false;
// >>> 변경/추가 >>> // setState 전에 mounted 체크 추가
      if (mounted) {
        setState(() {
// >>> 변경/추가 >>> // 필터링된 객체 리스트 사용
          _detectedObjects = objectsToShow;
// >>> 변경/추가 >>> // 회전 값도 여기서 최종 확정
          _imageRotation = _lastCalculatedRotation;
        });
      }

// >>> 변경/추가 >>> // _isBusy 해제 로직 위치 조정 (setState 후)
      if (!_isWaitingForRotation && !_isWaitingForDetection && _isBusy) {
        _isBusy = false;
      }
    } else if (message is List &&
        message.length == 2 &&
        message[0] is String &&
// >>> 변경/추가 >>> // toString() 추가하여 타입 안정성 확보
        message[0].toString().contains('Error')) {
      print('****** Object Detection Isolate Error: ${message[1]}');
      _isWaitingForDetection = false;
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
// >>> 변경/추가 >>> // Isolate 종료 또는 빈 메시지 수신 시 처리 로직 추가
    } else if (message == null || (message is List && message.isEmpty && message is! List<DetectedObject>)) {
// >>> 변경/추가 >>>
      print('****** Object Detection Isolate exited or sent empty/null message.');
// >>> 변경/추가 >>>
       _isWaitingForDetection = false;
// >>> 변경/추가 >>> // Isolate 종료 시 SendPort 무효화
// >>> 변경/추가 >>>
      if (_objectDetectionIsolateSendPort != null && message == null) {
// >>> 변경/추가 >>>
          _objectDetectionIsolateSendPort = null;
// >>> 변경/추가 >>>
          print("Object Detection Isolate SendPort invalidated due to Isolate exit.");
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>> // 오류 발생 시 기존 객체 제거
// >>> 변경/추가 >>>
      if (_detectedObjects.isNotEmpty && mounted) {
// >>> 변경/추가 >>>
        setState(() {
// >>> 변경/추가 >>>
          _detectedObjects = [];
// >>> 변경/추가 >>>
        });
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>>
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
// >>> 변경/추가 >>> // 예상치 못한 메시지 타입 처리 로직 추가
    } else {
// >>> 변경/추가 >>>
      print('****** Unexpected message from Object Detection Isolate: $message, type: ${message.runtimeType}');
// >>> 변경/추가 >>>
      _isWaitingForDetection = false;
// >>> 변경/추가 >>>
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
// >>> 변경/추가 >>>
    }
  }

  void _handleRotationResult(dynamic message) {
// >>> 변경/추가 >>>
    if (!mounted) return; // 위젯 unmount 시 처리 중단

    if (_imageRotationIsolateSendPort == null && message is SendPort) {
// >>> 변경/추가 >>>
      print("Image Rotation Isolate SendPort received via message."); // 디버그 로그
      _imageRotationIsolateSendPort = message;
    } else if (message is InputImageRotation?) {
      _isWaitingForRotation = false;
// >>> 변경/추가 >>> // 계산된 회전 값 저장
      _lastCalculatedRotation = message;
// >>> 변경/추가 >>> // 즉시 imageRotation 상태 업데이트
      _imageRotation = message;

      if (_pendingImageDataBytes != null &&
          _objectDetectionIsolateSendPort != null &&
// >>> 변경/추가 >>> // message(회전값) null 체크 추가
          message != null) {
        _isWaitingForDetection = true;
        _lastImageSize = Size(_pendingImageDataWidth!.toDouble(),
            _pendingImageDataHeight!.toDouble());

// >>> 변경/추가 >>> // 객체 탐지 Isolate에 Map 형태로 데이터 전달
// >>> 변경/추가 >>>
        final Map<String, dynamic> payload = {
// >>> 변경/추가 >>>
          'bytes': _pendingImageDataBytes!,
// >>> 변경/추가 >>>
          'width': _pendingImageDataWidth!,
// >>> 변경/추가 >>>
          'height': _pendingImageDataHeight!,
// >>> 변경/추가 >>> // InputImageRotation 객체 직접 전달
          'rotation': message,
// >>> 변경/추가 >>>
          'formatRaw': _pendingImageDataFormatRaw!,
// >>> 변경/추가 >>>
          'bytesPerRow': _pendingImageDataBytesPerRow!,
// >>> 변경/추가 >>>
        };
// >>> 변경/추가 >>>
        _objectDetectionIsolateSendPort!.send(payload);
// >>> 변경/추가 >>> // 전송 후 null 처리 명확화
        _pendingImageDataBytes = null;
      } else {
// >>> 변경/추가 >>> // 데이터 전송 안 되는 경우 디버그 로그 추가
// >>> 변경/추가 >>>
        if (message == null) print("Rotation calculation resulted in null, not sending to detection isolate.");
// >>> 변경/추가 >>>
        // if (_pendingImageDataBytes == null) print("Pending image data is null."); // This can be normal if no new image processed yet
// >>> 변경/추가 >>>
        // if (_objectDetectionIsolateSendPort == null) print("Object detection isolate send port is null.");

        if (!_isWaitingForDetection && _isBusy) _isBusy = false;
      }
    } else if (message is List &&
        message.length == 2 &&
        message[0] is String &&
// >>> 변경/추가 >>> // toString() 추가하여 타입 안정성 확보
        message[0].toString().contains('Error')) {
      print('****** Image Rotation Isolate Error: ${message[1]}');
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null;
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
// >>> 변경/추가 >>> // Isolate 종료 또는 빈 메시지 수신 시 처리 로직 추가
    } else if (message == null || (message is List && message.isEmpty && message is! InputImageRotation)) {
// >>> 변경/추가 >>>
       print('****** Image Rotation Isolate exited or sent empty/null message.');
// >>> 변경/추가 >>>
      _isWaitingForRotation = false;
// >>> 변경/추가 >>>
      _pendingImageDataBytes = null;
// >>> 변경/추가 >>> // Isolate 종료 시 SendPort 무효화
// >>> 변경/추가 >>>
      if (_imageRotationIsolateSendPort != null && message == null) {
// >>> 변경/추가 >>>
          _imageRotationIsolateSendPort = null;
// >>> 변경/추가 >>>
          print("Image Rotation Isolate SendPort invalidated due to Isolate exit.");
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>>
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
// >>> 변경/추가 >>> // 예상치 못한 메시지 타입 처리 로직 추가
    }
     else {
// >>> 변경/추가 >>>
      print('****** Unexpected message from Image Rotation Isolate: $message, type: ${message.runtimeType}');
// >>> 변경/추가 >>>
      _isWaitingForRotation = false;
// >>> 변경/추가 >>>
      _pendingImageDataBytes = null;
// >>> 변경/추가 >>>
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
// >>> 변경/추가 >>>
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
// >>> 변경/추가 >>> // 기존 카메라 컨트롤러가 있으면 먼저 해제하는 로직 추가
// >>> 변경/추가 >>>
    if (_cameraController != null && _cameraController!.value.isInitialized) {
// >>> 변경/추가 >>>
      print("Disposing previous camera controller before initializing a new one.");
// >>> 변경/추가 >>>
      await _stopCameraStream(); // 스트림 먼저 중지
// >>> 변경/추가 >>>
      await _cameraController!.dispose(); // 이전 컨트롤러 해제
// >>> 변경/추가 >>>
      _cameraController = null; // 참조 제거
// >>> 변경/추가 >>>
    }
// >>> 변경/추가 >>> // 초기화 시작 전 상태 업데이트
// >>> 변경/추가 >>>
     if (mounted) setState(() => _isCameraInitialized = false);

// >>> 변경/추가 >>>
    print("Initializing camera: ${cameraDescription.name} with lens direction ${cameraDescription.lensDirection}"); // 디버그 로그
    _cameraController = CameraController(
      cameraDescription,
// >>> 변경/추가 >>> // 해상도 medium -> high 변경
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();
// >>> 변경/추가 >>>
      print("Camera initialized. Preview size: ${_cameraController!.value.previewSize}, Aspect Ratio: ${_cameraController!.value.aspectRatio}"); // 초기화 정보 로그

// >>> 변경/추가 >>> // 스트림 시작을 초기화 성공 후에 호출
      await _startCameraStream();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _cameraIndex = widget.cameras.indexOf(cameraDescription);
        });
      }
// >>> 변경/추가 >>> // CameraException 처리 강화 (로그 및 SnackBar)
    } on CameraException catch (e) {
// >>> 변경/추가 >>>
      print('****** CameraException on initializeCamera for ${cameraDescription.name}: ${e.code} ${e.description}');
// >>> 변경/추가 >>>
      if (mounted) {
// >>> 변경/추가 >>>
        ScaffoldMessenger.of(context).showSnackBar(
// >>> 변경/추가 >>>
          SnackBar(content: Text('카메라 초기화 오류 (${cameraDescription.name}): ${e.description}')),
// >>> 변경/추가 >>>
        );
// >>> 변경/추가 >>> // 에러 시 상태 업데이트
// >>> 변경/추가 >>>
        setState(() => _isCameraInitialized = false);
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>> // 기타 Exception 처리 강화 (로그 및 SnackBar)
    } catch (e, stacktrace) {
// >>> 변경/추가 >>>
      print('****** Other Exception on initializeCamera for ${cameraDescription.name}: $e');
// >>> 변경/추가 >>>
      print(stacktrace);
// >>> 변경/추가 >>>
      if (mounted) {
// >>> 변경/추가 >>>
         ScaffoldMessenger.of(context).showSnackBar(
// >>> 변경/추가 >>>
          SnackBar(content: Text('알 수 없는 카메라 오류 발생 (${cameraDescription.name}).')),
// >>> 변경/추가 >>>
        );
// >>> 변경/추가 >>> // 에러 시 상태 업데이트
// >>> 변경/추가 >>>
        setState(() => _isCameraInitialized = false);
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>>
    }
  }

  Future<void> _startCameraStream() async {
// >>> 변경/추가 >>> // 스트림 시작 전 상태 체크 강화
// >>> 변경/추가 >>>
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
// >>> 변경/추가 >>>
      print("Cannot start stream: Camera not initialized.");
// >>> 변경/추가 >>>
      return;
// >>> 변경/추가 >>>
    }
// >>> 변경/추가 >>>
    if (_cameraController!.value.isStreamingImages) {
// >>> 변경/추가 >>>
      print("Stream already started.");
// >>> 변경/추가 >>>
      return;
// >>> 변경/추가 >>>
    }
    try {
      await _cameraController!.startImageStream(_processCameraImage);
// >>> 변경/추가 >>>
      print("Camera image stream started."); // 디버그 로그
    } catch (e, stacktrace) {
// >>> 변경/추가 >>> // 스트림 시작 오류 처리 강화 (로그 및 SnackBar)
// >>> 변경/추가 >>>
      print('****** Exception on startCameraStream: $e');
// >>> 변경/추가 >>>
      print(stacktrace);
// >>> 변경/추가 >>>
       if (mounted) {
// >>> 변경/추가 >>>
         ScaffoldMessenger.of(context).showSnackBar(
// >>> 변경/추가 >>>
          const SnackBar(content: Text('카메라 스트림 시작 오류.')),
// >>> 변경/추가 >>>
        );
// >>> 변경/추가 >>>
      }
// >>> 변경/추가 >>>
    }
  }

  Future<void> _stopCameraStream() async {
// >>> 변경/추가 >>> // 스트림 중지 전 상태 체크 강화
    if (_cameraController == null || !_cameraController!.value.isInitialized || !_cameraController!.value.isStreamingImages) {
      return;
    }
    try {
      await _cameraController!.stopImageStream();
// >>> 변경/추가 >>>
      print("Camera image stream stopped."); // 디버그 로그
    } catch (e, stacktrace) {
// >>> 변경/추가 >>> // 스트림 중지 오류 처리 강화 (로그)
// >>> 변경/추가 >>>
      print('****** Exception on stopCameraStream: $e');
// >>> 변경/추가 >>>
      print(stacktrace);
// >>> 변경/추가 >>> // finally 블록 사용하여 플래그 리셋 보장 및 mounted 체크 추가
    } finally {
// >>> 변경/추가 >>>
      if(mounted) {
        _isBusy = false;
        _isWaitingForRotation = false;
        _isWaitingForDetection = false;
        _pendingImageDataBytes = null;
      }
// >>> 변경/추가 >>>
    }
  }

  void _processCameraImage(CameraImage image) {
// >>> 변경/추가 >>> // 처리 시작 전 조건 체크 강화 (mounted 추가)
    if (!mounted || _isBusy || _imageRotationIsolateSendPort == null) {
      return;
    }
// >>> 변경/추가 >>> // _isBusy 설정 위치 조정
    _isBusy = true;
    _isWaitingForRotation = true;
    // --- 제거됨 --- _isWaitingForDetection = false; (여기서 설정 불필요)

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
      _pendingImageDataWidth = image.width;
      _pendingImageDataHeight = image.height;
// >>> 변경/추가 >>> // raw 값 저장 확인 (코드 변경 없음, 주석 추가)
      _pendingImageDataFormatRaw = image.format.raw;
      _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

      final camera = widget.cameras[_cameraIndex];
// >>> 변경/추가 >>> // context 사용 확인 (코드 변경 없음, 주석 추가)
      final orientation = MediaQuery.of(context).orientation;
// >>> 변경/추가 >>> // iOS/Android 플랫폼별 landscape 방향 처리 추가
      final DeviceOrientation deviceRotation = (orientation == Orientation.landscape)
// >>> 변경/추가 >>>
          ? (Platform.isIOS ? DeviceOrientation.landscapeRight : DeviceOrientation.landscapeLeft)
// >>> 변경/추가 >>>
          : DeviceOrientation.portraitUp;

// >>> 변경/추가 >>> // 회전 Isolate에 Map 형태로 데이터 전달
// >>> 변경/추가 >>>
      final Map<String, dynamic> rotationPayload = {
// >>> 변경/추가 >>>
        'sensorOrientation': camera.sensorOrientation,
// >>> 변경/추가 >>> // DeviceOrientation 대신 index 전달
        'deviceOrientationIndex': deviceRotation.index,
// >>> 변경/추가 >>>
      };
// >>> 변경/추가 >>>
      _imageRotationIsolateSendPort!.send(rotationPayload);
// >>> 변경/추가 >>> // 이미지 처리 중 오류 핸들링 강화
    } catch (e, stacktrace) {
// >>> 변경/추가 >>>
      print("****** Error preparing image for rotation isolate: $e");
// >>> 변경/추가 >>>
      print(stacktrace);
// >>> 변경/추가 >>> // 오류 시 pending 데이터 초기화
      _pendingImageDataBytes = null;
// >>> 변경/추가 >>>
      _isWaitingForRotation = false;
// >>> 변경/추가 >>> // 오류 시 _isBusy 해제
      _isBusy = false;
// >>> 변경/추가 >>>
    }
  }

  void _switchCamera() {
// >>> 변경/추가 >>> // _isBusy 체크 확인 (코드 변경 없음, 주석 추가)
    if (widget.cameras.length < 2 || _isBusy) return;
// >>> 변경/추가 >>>
    print("Switching camera..."); // 디버그 로그
    final newIndex = (_cameraIndex + 1) % widget.cameras.length;
// >>> 변경/추가 >>> // 스트림 중지 후 카메라 초기화 확인 (코드 변경 없음, 주석 추가)
    _stopCameraStream().then((_) {
      _initializeCamera(widget.cameras[newIndex]);
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget cameraPreviewWidget;

    if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized) {
      cameraPreviewWidget = CameraPreview(_cameraController!);
    } else {
// >>> 변경/추가 >>> // 카메라 초기화 중/실패 시 표시 위젯 개선
// >>> 변경/추가 >>>
      cameraPreviewWidget = Column(
// >>> 변경/추가 >>>
        mainAxisAlignment: MainAxisAlignment.center,
// >>> 변경/추가 >>>
        children: [
// >>> 변경/추가 >>>
          const CircularProgressIndicator(),
// >>> 변경/추가 >>>
          const SizedBox(height: 10),
// >>> 변경/추가 >>>
          Text(widget.cameras.isEmpty ? '카메라 없음' : '카메라 초기화 중...'),
// >>> 변경/추가 >>>
        ],
// >>> 변경/추가 >>>
      );
// >>> 변경/추가 >>>
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 객체 탐지'),
        actions: [
          if (widget.cameras.length > 1)
            IconButton(
              icon: Icon(
// >>> 변경/추가 >>> // widget.cameras 사용하도록 수정 (_cameras -> widget.cameras)
                widget.cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                    ? Icons.camera_front
                    : Icons.camera_rear,
              ),
// >>> 변경/추가 >>> // _isBusy일 때 버튼 비활성화
              onPressed: _isBusy ? null : _switchCamera,
            ),
        ],
      ),
// >>> 변경/추가 >>> // SafeArea 적용
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
// >>> 변경/추가 >>> // 카메라 미리보기 위젯 표시 로직 개선 (Center 및 AspectRatio 위치 조정)
// >>> 변경/추가 >>>
            if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized)
// >>> 변경/추가 >>>
              Center(
// >>> 변경/추가 >>>
                child: AspectRatio(
// >>> 변경/추가 >>>
                  aspectRatio: _cameraController!.value.aspectRatio,
// >>> 변경/추가 >>>
                  child: cameraPreviewWidget,
// >>> 변경/추가 >>>
                ),
// >>> 변경/추가 >>>
              )
// >>> 변경/추가 >>>
            else
// >>> 변경/추가 >>>
              Center(child: cameraPreviewWidget),

// >>> 변경/추가 >>> // Painter 호출 조건 확인 (코드 변경 없음, 주석 추가)
            if (_isCameraInitialized && _detectedObjects.isNotEmpty && _lastImageSize != null && _imageRotation != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  return CustomPaint(
// >>> 변경/추가 >>> // size 명시
                    size: constraints.biggest,
                    painter: ObjectPainter(
                      objects: _detectedObjects,
// >>> 변경/추가 >>> // imageSize 전달 확인 (코드 변경 없음, 주석 추가)
                      imageSize: _lastImageSize!,
// >>> 변경/추가 >>> // 화면 크기 전달 추가
                      screenSize: constraints.biggest,
                      rotation: _imageRotation!,
                      cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
                    ),
                  );
                }
              ),

          // --- 제거됨 ---
          // 이전 코드의 _isBusy 시 표시되던 반투명 오버레이 및 CircularProgressIndicator
          /*
           if (_isBusy)
             Container(
               color: Colors.black.withOpacity(0.3),
               child: const Center(
                 child: CircularProgressIndicator(color: Colors.white),
               ),
             ),
          */
          ],
        ),
      ),
    );
  }
}
