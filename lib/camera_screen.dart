// lib/camera_screen.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data'; // Uint8List
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart'; // DeviceOrientation
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'logic/mlkit_logic.dart'; // ML Kit 로직 임포트
import 'ui/object_painter.dart'; // 메인 Painter 임포트
import 'dart:io'; // Platform

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
  bool _isBusy = false;
  List<DetectedObject> _detectedObjects = [];
  InputImageRotation? _imageRotation;
  late ObjectDetector _objectDetector;
  Size? _lastImageSize;

  // Isolate 관련
  Isolate? _objectDetectionIsolate;
  Isolate? _imageRotationIsolate;
  late ReceivePort _objectDetectionReceivePort;
  late ReceivePort _imageRotationReceivePort;
  SendPort? _objectDetectionIsolateSendPort;
  SendPort? _imageRotationIsolateSendPort;
  StreamSubscription? _objectDetectionSubscription;
  StreamSubscription? _imageRotationSubscription;

  bool _isWaitingForRotation = false;
  bool _isWaitingForDetection = false;
  InputImageRotation? _lastCalculatedRotation;
  Uint8List? _pendingImageDataBytes;
  int? _pendingImageDataWidth;
  int? _pendingImageDataHeight;
  int? _pendingImageDataFormatRaw;
  int? _pendingImageDataBytesPerRow;

  @override
  void initState() {
    super.initState();
    _objectDetector = initializeObjectDetector(); // ML Kit 로직 파일에서 초기화 함수 호출
    _spawnIsolates().then((_) {
      if (widget.cameras.isNotEmpty) {
        _initializeCamera(widget.cameras[0]); // 카메라 초기화
      }
    }).catchError((e, stacktrace) {
      print("****** initState: Error spawning isolates: $e");
      // ... 오류 처리 UI ...
    });
  }

  @override
  void dispose() {
    _stopCameraStream();
    _objectDetectionSubscription?.cancel();
    _imageRotationSubscription?.cancel();
    _killIsolates();
    _cameraController?.dispose();
    _objectDetector.close();
    super.dispose();
  }

  // --- Isolate 생성 및 관리 ---
  Future<void> _spawnIsolates() async {
     Completer<void> rotationPortCompleter = Completer();
     Completer<void> detectionPortCompleter = Completer();
     final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance; // ML Kit용 토큰

     if (rootIsolateToken == null) { /* ... 오류 처리 ... */ throw Exception("Root token null"); }

     // 탐지 Isolate
     _objectDetectionReceivePort = ReceivePort();
     _objectDetectionIsolate = await Isolate.spawn(
       detectObjectsIsolateEntry, // mlkit_logic.dart 에 정의됨
       [_objectDetectionReceivePort.sendPort, rootIsolateToken],
       onError: _objectDetectionReceivePort.sendPort,
       onExit: _objectDetectionReceivePort.sendPort,
     );
     _objectDetectionSubscription = _objectDetectionReceivePort.listen(_handleDetectionResult);

     // 회전 Isolate
     _imageRotationReceivePort = ReceivePort();
     _imageRotationIsolate = await Isolate.spawn(
       getImageRotationIsolateEntry, // mlkit_logic.dart 에 정의됨
       _imageRotationReceivePort.sendPort,
        onError: _imageRotationReceivePort.sendPort,
        onExit: _imageRotationReceivePort.sendPort,
     );
    _imageRotationSubscription = _imageRotationReceivePort.listen(_handleRotationResult);

    // Isolate 준비 대기
     try {
       await Future.wait([
         rotationPortCompleter.future.timeout(const Duration(seconds: 5)),
         detectionPortCompleter.future.timeout(const Duration(seconds: 5))
       ]);
     } catch (e) { /* ... 타임아웃/오류 처리 ... */ _killIsolates(); throw e; }
  }

  void _killIsolates() {
    try { _objectDetectionIsolate?.kill(priority: Isolate.immediate); } catch(e) {}
    try { _imageRotationIsolate?.kill(priority: Isolate.immediate); } catch(e) {}
    // ... 변수 null 처리 ...
     _objectDetectionIsolate = null; _imageRotationIsolate = null;
     _objectDetectionIsolateSendPort = null; _imageRotationIsolateSendPort = null;
  }

  // --- Isolate 결과 처리 핸들러 ---
  void _handleDetectionResult(dynamic message){
      if (_objectDetectionIsolateSendPort == null && message is SendPort) {
        _objectDetectionIsolateSendPort = message;
        // detectionPortCompleter.complete(); // Completer 사용 시 필요
      } else if (message is List<DetectedObject>) {
        _isWaitingForDetection = false;
        if (mounted) {
          setState(() {
            _detectedObjects = message;
            _imageRotation = _lastCalculatedRotation;
          });
        }
        if (!_isWaitingForRotation && !_isWaitingForDetection && _isBusy) {
          _isBusy = false;
        }
      } else if (message is List && message.length == 2 && message[0] is String && message[0].contains('Error')) {
        print('****** Object Detection Isolate Error: ${message[1]}');
        _isWaitingForDetection = false;
        if (!_isWaitingForRotation) _isBusy = false;
      } else { /* ... 예상 외 메시지 ... */ }
  }

  void _handleRotationResult(dynamic message){
     if (_imageRotationIsolateSendPort == null && message is SendPort) {
       _imageRotationIsolateSendPort = message;
       // rotationPortCompleter.complete(); // Completer 사용 시 필요
     } else if (message is InputImageRotation?) {
       _isWaitingForRotation = false;
       _lastCalculatedRotation = message;

       if (_pendingImageDataBytes != null && _objectDetectionIsolateSendPort != null && message != null) {
         _isWaitingForDetection = true;
         _lastImageSize = Size(_pendingImageDataWidth!.toDouble(), _pendingImageDataHeight!.toDouble());
         _objectDetectionIsolateSendPort!.send([
           _pendingImageDataBytes!, _pendingImageDataWidth!, _pendingImageDataHeight!,
           message, _pendingImageDataFormatRaw!, _pendingImageDataBytesPerRow!,
         ]);
         _pendingImageDataBytes = null;
       } else {
         if (!_isWaitingForDetection && _isBusy) _isBusy = false;
       }
     } else if (message is List && message.length == 2 && message[0] is String && message[0].contains('Error')) {
       print('****** Image Rotation Isolate Error: ${message[1]}');
       _isWaitingForRotation = false; _pendingImageDataBytes = null;
       if (!_isWaitingForDetection) _isBusy = false;
     } else { /* ... 예상 외 메시지 ... */ }
  }


  // --- 카메라 관련 로직 ---
  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_cameraController != null) { /* ... 기존 컨트롤러 정리 ... */ await _stopCameraStream(); await _cameraController!.dispose(); _cameraController = null; if(mounted) setState(() => _isCameraInitialized = false); }

    _cameraController = CameraController(
      cameraDescription, ResolutionPreset.medium, enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    try {
      await _cameraController!.initialize();
      await _startCameraStream();
      if(mounted) setState(() { _isCameraInitialized = true; _cameraIndex = widget.cameras.indexOf(cameraDescription); });
    } on CameraException catch (e) { /* ... 오류 처리 ... */ }
    catch (e) { /* ... 오류 처리 ... */ }
  }

  Future<void> _startCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized || _cameraController!.value.isStreamingImages) return;
    try {
      await _cameraController!.startImageStream(_processCameraImage); // 프레임 처리 함수 연결
    } catch (e) { /* ... 오류 처리 ... */ }
  }

  Future<void> _stopCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isStreamingImages) return;
    try { await _cameraController!.stopImageStream(); }
    catch (e) { /* ... 오류 처리 ... */ }
    _isBusy = false; _isWaitingForRotation = false; _isWaitingForDetection = false; _pendingImageDataBytes = null;
  }

  void _processCameraImage(CameraImage image) {
     if (_isBusy || _imageRotationIsolateSendPort == null || _objectDetectionIsolateSendPort == null) return;
     _isBusy = true; _isWaitingForRotation = true; _isWaitingForDetection = false;

     try {
       final WriteBuffer allBytes = WriteBuffer();
       for (final Plane plane in image.planes) allBytes.putUint8List(plane.bytes);
       _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
       _pendingImageDataWidth = image.width; _pendingImageDataHeight = image.height;
       _pendingImageDataFormatRaw = image.format.raw; _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

       final camera = widget.cameras[_cameraIndex];
       final orientation = MediaQuery.of(context).orientation;
       final DeviceOrientation deviceRotation = (orientation == Orientation.landscape) ? DeviceOrientation.landscapeLeft : DeviceOrientation.portraitUp;

       _imageRotationIsolateSendPort!.send([camera.sensorOrientation, deviceRotation]); // 회전 계산 요청
     } catch (e, stacktrace) { /* ... 오류 처리 및 상태 초기화 ... */ print("****** Error processing image: $e"); _pendingImageDataBytes = null; _isWaitingForRotation = false; _isBusy = false;}
  }

  void _switchCamera() {
     if (widget.cameras.length < 2 || _isBusy) return;
     final newIndex = (_cameraIndex + 1) % widget.cameras.length;
     _stopCameraStream().then((_) {
       _initializeCamera(widget.cameras[newIndex]);
     });
  }

  // --- UI 빌드 ---
  @override
  Widget build(BuildContext context) {
    // 카메라 미리보기 위젯
    Widget cameraPreviewWidget;
    if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized) {
      cameraPreviewWidget = AspectRatio(
          aspectRatio: _cameraController!.value.aspectRatio,
          child: CameraPreview(_cameraController!),
      );
    } else {
      cameraPreviewWidget = const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 객체 탐지'),
        actions: [
          if (widget.cameras.length > 1) IconButton( // 카메라 전환 버튼
              icon: Icon(_cameras[_cameraIndex].lensDirection == CameraLensDirection.front ? Icons.camera_front : Icons.camera_rear),
              onPressed: _switchCamera,
            ),
        ],
      ),
      body: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: cameraPreviewWidget), // 카메라 미리보기

            // 결과 그리기
            if (_isCameraInitialized && _detectedObjects.isNotEmpty && _lastImageSize != null && _imageRotation != null)
              LayoutBuilder(
                  builder: (context, constraints) {
                    return CustomPaint( // ObjectPainter 사용
                      size: constraints.biggest,
                      painter: ObjectPainter(
                        objects: _detectedObjects,
                        imageSize: _lastImageSize!,
                        rotation: _imageRotation!,
                        cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
                      ),
                    );
                  }
              ),

            if (_isBusy) // 로딩 표시
              Container(color: Colors.black.withOpacity(0.3), child: const Center(child: CircularProgressIndicator(color: Colors.white))),
          ],
        ),
    );
  }
}