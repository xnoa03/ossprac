// lib/camera_screen.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data'; // Uint8List
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart'; // DeviceOrientation, RootIsolateToken
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'logic/mlkit_logic.dart'; // ML Kit 로직 임포트
import 'ui/object_painter.dart'; // 메인 Painter 임포트
import 'dart:io'; // Platform

// Isolate에 데이터를 전달하기 위한 간단한 홀더 클래스
class IsolateDataHolder {
  final SendPort mainSendPort;
  final RootIsolateToken? rootIsolateToken; // ML Kit은 RootIsolateToken 필요
  // final dynamic data; // Isolate에 전달할 초기 데이터 (현재 구조에서는 사용 안함)

  IsolateDataHolder(this.mainSendPort, this.rootIsolateToken);
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
    print("RealtimeObjectDetectionScreen: initState called");
    _objectDetector = initializeObjectDetector(); // ML Kit 로직 파일에서 초기화 함수 호출

    // Completer를 사용한 대기 로직 없이 Isolate를 스폰하고,
    // SendPort는 비동기적으로 설정되도록 합니다.
    _spawnIsolates().then((_) {
      if (widget.cameras.isNotEmpty) {
        _initializeCamera(widget.cameras[0]); // 카메라 초기화
      } else {
        print("****** No cameras available!");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('사용 가능한 카메라가 없습니다.')),
          );
        }
      }
    }).catchError((e, stacktrace) {
      print("****** initState: Error spawning isolates or initializing camera: $e");
      print(stacktrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('초기화 중 오류 발생: $e')),
        );
      }
    });
  }

  @override
  void dispose() {
    print("RealtimeObjectDetectionScreen: dispose called");
    _stopCameraStream(); // 스트림 먼저 중지
    _objectDetectionSubscription?.cancel();
    _imageRotationSubscription?.cancel();
    _killIsolates(); // Isolate 종료
    _cameraController?.dispose().then((_) {
      print("CameraController disposed");
    }).catchError((e) {
      print("Error disposing camera controller: $e");
    });
    _objectDetector.close().then((_) {
      print("ObjectDetector closed");
    }).catchError((e){
      print("Error closing object detector: $e");
    });
    super.dispose();
  }

  // --- Isolate 생성 및 관리 ---
  Future<void> _spawnIsolates() async {
    print("Spawning Isolates...");
    final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;

    if (rootIsolateToken == null) {
      print("****** RootIsolateToken is null. ML Kit in Isolate might not work.");
      // 이 경우 Isolate 스폰을 중단하거나, 사용자에게 알릴 수 있습니다.
      return; // 스폰 중단
    }

    // 탐지 Isolate
    _objectDetectionReceivePort = ReceivePort();
    _objectDetectionIsolate = await Isolate.spawn(
      detectObjectsIsolateEntry,
      IsolateDataHolder(_objectDetectionReceivePort.sendPort, rootIsolateToken),
      onError: _objectDetectionReceivePort.sendPort,
      onExit: _objectDetectionReceivePort.sendPort,
      debugName: "ObjectDetectionIsolate"
    );
    _objectDetectionSubscription =
        _objectDetectionReceivePort.listen(_handleDetectionResult);
    print("Object Detection Isolate spawned and listener attached.");

    // 회전 Isolate
    _imageRotationReceivePort = ReceivePort();
    _imageRotationIsolate = await Isolate.spawn(
      getImageRotationIsolateEntry,
      _imageRotationReceivePort.sendPort, // 회전 Isolate는 메인 SendPort만 필요
      onError: _imageRotationReceivePort.sendPort,
      onExit: _imageRotationReceivePort.sendPort,
      debugName: "ImageRotationIsolate"
    );
    _imageRotationSubscription =
        _imageRotationReceivePort.listen(_handleRotationResult);
    print("Image Rotation Isolate spawned and listener attached.");
  }

  void _killIsolates() {
    print("Killing Isolates...");
    try {
      _objectDetectionIsolate?.kill(priority: Isolate.immediate);
      print("Object Detection Isolate kill signal sent.");
    } catch (e) {
      print("Error killing object detection isolate: $e");
    }
    try {
      _imageRotationIsolate?.kill(priority: Isolate.immediate);
      print("Image Rotation Isolate kill signal sent.");
    } catch (e) {
      print("Error killing image rotation isolate: $e");
    }
    _objectDetectionIsolate = null;
    _imageRotationIsolate = null;
    _objectDetectionIsolateSendPort = null;
    _imageRotationIsolateSendPort = null;
    // ReceivePort는明시적으로 close할 필요 없음, Isolate 종료 시 정리됨
  }

  // --- Isolate 결과 처리 핸들러 ---
  void _handleDetectionResult(dynamic message) {
    if (!mounted) return; // 위젯이 unmounted된 후에는 상태 변경 시도 방지

    if (_objectDetectionIsolateSendPort == null && message is SendPort) {
      print("Object Detection Isolate SendPort received via message.");
      _objectDetectionIsolateSendPort = message;
    } else if (message is List<DetectedObject>) {
      // print("Detected objects: ${message.length}");
      _isWaitingForDetection = false;
      setState(() {
        _detectedObjects = message;
        _imageRotation = _lastCalculatedRotation; // 회전 값 동기화
      });
      if (!_isWaitingForRotation && !_isWaitingForDetection && _isBusy) {
        _isBusy = false;
      }
    } else if (message is List &&
        message.length == 2 &&
        message[0] is String &&
        message[0].toString().contains('Error')) {
      print('****** Object Detection Isolate Error: ${message[1]}');
      _isWaitingForDetection = false;
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    } else if (message == null || (message is List && message.isEmpty && message is! List<DetectedObject>)) {
      // Isolate 종료 시 null 또는 빈 리스트를 보낼 수 있음 (onExit 핸들러)
      print('****** Object Detection Isolate exited or sent empty/null message.');
      _isWaitingForDetection = false;
      if (_objectDetectionIsolateSendPort != null && message == null) { // Isolate가 예기치 않게 종료된 경우
          _objectDetectionIsolateSendPort = null; // SendPort 무효화
          print("Object Detection Isolate SendPort invalidated due to Isolate exit.");
      }
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    } else {
      print('****** Unexpected message from Object Detection Isolate: $message, type: ${message.runtimeType}');
    }
  }

  void _handleRotationResult(dynamic message) {
    if (!mounted) return;

    if (_imageRotationIsolateSendPort == null && message is SendPort) {
      print("Image Rotation Isolate SendPort received via message.");
      _imageRotationIsolateSendPort = message;
    } else if (message is InputImageRotation?) {
      // print("Calculated rotation: $message");
      _isWaitingForRotation = false;
      _lastCalculatedRotation = message; // Painter가 사용할 최종 회전값
      _imageRotation = message; // setState에서 UI 업데이트 시 사용 (CustomPaint 조건부 렌더링)


      if (_pendingImageDataBytes != null &&
          _objectDetectionIsolateSendPort != null &&
          message != null) { // message(InputImageRotation)가 null이 아닐 때만 전송
        _isWaitingForDetection = true;
        _lastImageSize = Size(_pendingImageDataWidth!.toDouble(), _pendingImageDataHeight!.toDouble());

        final Map<String, dynamic> payload = {
          'bytes': _pendingImageDataBytes!,
          'width': _pendingImageDataWidth!,
          'height': _pendingImageDataHeight!,
          'rotation': message, // InputImageRotation
          'formatRaw': _pendingImageDataFormatRaw!,
          'bytesPerRow': _pendingImageDataBytesPerRow!,
        };
        _objectDetectionIsolateSendPort!.send(payload);
        _pendingImageDataBytes = null; // 전송 후 초기화
      } else {
        if (message == null) print("Rotation calculation resulted in null, not sending to detection isolate.");
        if (_pendingImageDataBytes == null) print("Pending image data is null.");
        if (_objectDetectionIsolateSendPort == null) print("Object detection isolate send port is null.");

        if (!_isWaitingForDetection && _isBusy) _isBusy = false;
      }
    } else if (message is List &&
        message.length == 2 &&
        message[0] is String &&
        message[0].toString().contains('Error')) {
      print('****** Image Rotation Isolate Error: ${message[1]}');
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null;
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
    } else if (message == null || (message is List && message.isEmpty && message is! InputImageRotation)) {
       print('****** Image Rotation Isolate exited or sent empty/null message.');
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null;
      if (_imageRotationIsolateSendPort != null && message == null) {
          _imageRotationIsolateSendPort = null;
          print("Image Rotation Isolate SendPort invalidated due to Isolate exit.");
      }
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
    }
     else {
      print('****** Unexpected message from Image Rotation Isolate: $message, type: ${message.runtimeType}');
    }
  }

  // --- 카메라 관련 로직 ---
  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      print("Disposing previous camera controller before initializing a new one.");
      await _stopCameraStream(); // 스트림 중지
      await _cameraController!.dispose(); // 이전 컨트롤러 확실히 해제
      _cameraController = null; // null로 설정
    }
     if (mounted) setState(() => _isCameraInitialized = false); // 초기화 중 상태로 UI 업데이트

    print("Initializing camera: ${cameraDescription.name} with lens direction ${cameraDescription.lensDirection}");
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.high, // 화질 향상을 위해 high 시도, 문제 시 medium으로 복귀
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 // Android는 YUV(NV21)이 ML Kit 처리 효율에 좋음
          : ImageFormatGroup.bgra8888, // iOS는 BGRA8888이 일반적
    );

    try {
      await _cameraController!.initialize();
      print("Camera initialized. Preview size: ${_cameraController!.value.previewSize}, Aspect Ratio: ${_cameraController!.value.aspectRatio}");

      // 중요: 실제 이미지 스트림의 해상도는 previewSize와 다를 수 있음.
      // _lastImageSize는 _processCameraImage 또는 _handleRotationResult에서 CameraImage.width/height로 설정하는 것이 더 정확함.

      await _startCameraStream(); // 이미지 스트림 시작

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _cameraIndex = widget.cameras.indexOf(cameraDescription);
          // _lastImageSize를 여기서 설정하면 CameraPreview의 크기일 수 있어 ML Kit 처리 이미지 크기와 다를 수 있음
          // 정확한 imageSize는 CameraImage 객체에서 가져오는 것이 좋음
        });
      }
    } on CameraException catch (e) {
      print('****** CameraException on initializeCamera for ${cameraDescription.name}: ${e.code} ${e.description}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('카메라 초기화 오류 (${cameraDescription.name}): ${e.description}')),
        );
        setState(() => _isCameraInitialized = false);
      }
    } catch (e, stacktrace) {
      print('****** Other Exception on initializeCamera for ${cameraDescription.name}: $e');
      print(stacktrace);
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('알 수 없는 카메라 오류 발생 (${cameraDescription.name}).')),
        );
        setState(() => _isCameraInitialized = false);
      }
    }
  }

  Future<void> _startCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print("Cannot start stream: Camera not initialized.");
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      print("Stream already started.");
      return;
    }
    try {
      // 이전 스트림 리스너가 남아있을 수 있으므로, 중지 후 시작 또는 플래그 관리 필요
      // 여기서는 initializeCamera에서 이전 컨트롤러를 dispose하므로 새 컨트롤러에는 리스너 없음
      await _cameraController!.startImageStream(_processCameraImage); // 프레임 처리 함수 연결
      print("Camera image stream started.");
    } catch (e, stacktrace) {
      print('****** Exception on startCameraStream: $e');
      print(stacktrace);
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('카메라 스트림 시작 오류.')),
        );
      }
    }
  }

  Future<void> _stopCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized || !_cameraController!.value.isStreamingImages) {
      // print("Cannot stop stream: Camera not initialized or not streaming.");
      return;
    }
    try {
      await _cameraController!.stopImageStream();
      print("Camera image stream stopped.");
    } catch (e, stacktrace) {
      print('****** Exception on stopCameraStream: $e');
      print(stacktrace);
    } finally { // 스트림 중지 시 관련 상태 초기화
      if(mounted) { // mounted 체크 추가
        _isBusy = false;
        _isWaitingForRotation = false;
        _isWaitingForDetection = false;
        _pendingImageDataBytes = null;
      }
    }
  }

  void _processCameraImage(CameraImage image) {
    if (!mounted || _isBusy || _imageRotationIsolateSendPort == null) {
      // if (_isBusy) print("_processCameraImage: Busy, skipping frame.");
      // if (_imageRotationIsolateSendPort == null) print("_processCameraImage: Rotation Isolate SendPort is null, skipping frame.");
      return;
    }
    _isBusy = true;
    _isWaitingForRotation = true;
    // _isWaitingForDetection = false; // Will be set to true after rotation is known and data sent to detection isolate

    try {
      // print("Processing camera image: ${image.width}x${image.height}, format: ${image.format.group}");
      final WriteBuffer allBytes = WriteBuffer();
      // NV21의 경우 Y 평면 다음에 UV 평면이 옴. UV는 interleaved.
      // BGRA의 경우 단일 평면.
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
      _pendingImageDataWidth = image.width;
      _pendingImageDataHeight = image.height;
      _pendingImageDataFormatRaw = image.format.raw;
      _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

      final camera = widget.cameras[_cameraIndex];
      final orientation = MediaQuery.of(context).orientation; // build context 종속적이므로 주의
      final DeviceOrientation deviceRotation = (orientation == Orientation.landscape)
          ? (Platform.isIOS ? DeviceOrientation.landscapeRight : DeviceOrientation.landscapeLeft) // iOS는 landscapeRight가 일반적인 홈버튼 오른쪽 기준
          : DeviceOrientation.portraitUp;

      final Map<String, dynamic> rotationPayload = {
        'sensorOrientation': camera.sensorOrientation,
        'deviceOrientationIndex': deviceRotation.index, // enum의 index로 전달
        // 'lensDirection': camera.lensDirection.index // 필요시 전달
      };
      _imageRotationIsolateSendPort!.send(rotationPayload); // 회전 계산 요청
    } catch (e, stacktrace) {
      print("****** Error preparing image for rotation isolate: $e");
      print(stacktrace);
      _pendingImageDataBytes = null; // 오류 시 정리
      _isWaitingForRotation = false;
      _isBusy = false; // 오류 발생 시 _isBusy 해제
    }
  }

  void _switchCamera() {
    if (widget.cameras.length < 2 || _isBusy) return; // 이미 처리 중이면 전환 안 함
    print("Switching camera...");
    final newIndex = (_cameraIndex + 1) % widget.cameras.length;
    // 기존 스트림 및 컨트롤러 정리 후 새 카메라 초기화
    _stopCameraStream().then((_) {
      // _cameraController?.dispose(); // _initializeCamera 내부에서 처리
      _initializeCamera(widget.cameras[newIndex]);
    });
  }

  // --- UI 빌드 ---
  @override
  Widget build(BuildContext context) {
    // print("CameraScreen build called. isCameraInitialized: $_isCameraInitialized, detectedObjects: ${_detectedObjects.length}");
    Widget cameraPreviewWidget;
    Size? previewSizeOnScreen;

    if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized) {
      // CameraPreview를 화면에 맞추기 위한 로직이 중요 (AspectRatio + FittedBox or LayoutBuilder)
      // 현재는 AspectRatio만 사용 중. 이것이 CustomPaint의 크기와 어떻게 연관되는지 중요.
      cameraPreviewWidget = CameraPreview(_cameraController!);

      // LayoutBuilder를 사용하여 CameraPreview가 실제로 차지하는 화면상의 크기를 얻을 수 있음
      // 하지만 ObjectPainter는 Stack의 자식으로 LayoutBuilder를 이미 사용하고 있으므로,
      // 그 크기(constraints.biggest)를 screenSize로 활용할 수 있음.
    } else {
      cameraPreviewWidget = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 10),
          Text(widget.cameras.isEmpty ? '카메라 없음' : '카메라 초기화 중...'),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 객체 탐지'),
        actions: [
          if (widget.cameras.length > 1)
            IconButton(
              icon: Icon(
                widget.cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                    ? Icons.camera_front
                    : Icons.camera_rear,
              ),
              onPressed: _isBusy ? null : _switchCamera, // 바쁠 때는 비활성화
            ),
        ],
      ),
      body: SafeArea( // SafeArea 추가하여 노치 등 시스템 UI 피하기
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized)
              Center( // 카메라 프리뷰를 중앙에 배치하고, 크기 조절은 AspectRatio에 맡김
                child: AspectRatio(
                  aspectRatio: _cameraController!.value.aspectRatio,
                  child: cameraPreviewWidget,
                ),
              )
            else
              Center(child: cameraPreviewWidget), // 초기화 중/실패 시 메시지 표시

            // 결과 그리기
            if (_isCameraInitialized && _detectedObjects.isNotEmpty && _lastImageSize != null && _imageRotation != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  // print("Painter LayoutBuilder: size=${constraints.biggest}, imageSize=$_lastImageSize, rotation=$_imageRotation");
                  return CustomPaint(
                    size: constraints.biggest, // LayoutBuilder로부터 실제 그릴 영역의 크기 확보
                    painter: ObjectPainter(
                      objects: _detectedObjects,
                      imageSize: _lastImageSize!, // ML Kit이 처리한 이미지 크기
                      screenSize: constraints.biggest, // CustomPaint가 그려질 위젯의 크기
                      rotation: _imageRotation!,
                      cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
                    ),
                  );
                }
              ),

            if (_isBusy && _isCameraInitialized) // 로딩 표시는 카메라 초기화 후, 작업 중일 때만
              Container(
                color: Colors.black.withOpacity(0.5),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 8),
                      Text("처리 중...", style: TextStyle(color: Colors.white, fontSize: 16)),
                    ],
                  )
                ),
              ),
          ],
        ),
      ),
    );
  }
}