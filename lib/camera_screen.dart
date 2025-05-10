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
  List<DetectedObject> _detectedObjects = []; // 항상 이 리스트를 Painter에 전달 (내용이 0 또는 1개 객체)
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

  Future<void> _spawnIsolates() async {
    print("Spawning Isolates...");
    final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;

    if (rootIsolateToken == null) {
      print("****** RootIsolateToken is null. ML Kit in Isolate might not work.");
      return; 
    }

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

    _imageRotationReceivePort = ReceivePort();
    _imageRotationIsolate = await Isolate.spawn(
      getImageRotationIsolateEntry,
      _imageRotationReceivePort.sendPort, 
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
  }

  void _handleDetectionResult(dynamic message) {
    if (!mounted) return; 

    if (_objectDetectionIsolateSendPort == null && message is SendPort) {
      print("Object Detection Isolate SendPort received via message.");
      _objectDetectionIsolateSendPort = message;
    } else if (message is List<DetectedObject>) {
      List<DetectedObject> objectsToShow = []; 

      if (message.isNotEmpty) {
        DetectedObject closestObject = message.reduce((curr, next) {
          final double areaCurr = curr.boundingBox.width * curr.boundingBox.height;
          final double areaNext = next.boundingBox.width * next.boundingBox.height;
          return areaCurr > areaNext ? curr : next;
        });
        objectsToShow.add(closestObject);
      }

      _isWaitingForDetection = false;
      if (mounted) { 
        setState(() {
          _detectedObjects = objectsToShow; 
          _imageRotation = _lastCalculatedRotation; 
        });
      }
      
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
      print('****** Object Detection Isolate exited or sent empty/null message.');
       _isWaitingForDetection = false;
      if (_objectDetectionIsolateSendPort != null && message == null) {
          _objectDetectionIsolateSendPort = null; 
          print("Object Detection Isolate SendPort invalidated due to Isolate exit.");
      }
      if (_detectedObjects.isNotEmpty && mounted) { 
        setState(() {
          _detectedObjects = [];
        });
      }
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    } else {
      print('****** Unexpected message from Object Detection Isolate: $message, type: ${message.runtimeType}');
      _isWaitingForDetection = false;
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    }
  }

  void _handleRotationResult(dynamic message) {
    if (!mounted) return;

    if (_imageRotationIsolateSendPort == null && message is SendPort) {
      print("Image Rotation Isolate SendPort received via message.");
      _imageRotationIsolateSendPort = message;
    } else if (message is InputImageRotation?) {
      _isWaitingForRotation = false;
      _lastCalculatedRotation = message; 
      _imageRotation = message; 

      if (_pendingImageDataBytes != null &&
          _objectDetectionIsolateSendPort != null &&
          message != null) { 
        _isWaitingForDetection = true;
        _lastImageSize = Size(_pendingImageDataWidth!.toDouble(),
            _pendingImageDataHeight!.toDouble());

        final Map<String, dynamic> payload = {
          'bytes': _pendingImageDataBytes!,
          'width': _pendingImageDataWidth!,
          'height': _pendingImageDataHeight!,
          'rotation': message, 
          'formatRaw': _pendingImageDataFormatRaw!,
          'bytesPerRow': _pendingImageDataBytesPerRow!,
        };
        _objectDetectionIsolateSendPort!.send(payload);
        _pendingImageDataBytes = null; 
      } else {
        if (message == null) print("Rotation calculation resulted in null, not sending to detection isolate.");
        // if (_pendingImageDataBytes == null) print("Pending image data is null."); // This can be normal if no new image processed yet
        // if (_objectDetectionIsolateSendPort == null) print("Object detection isolate send port is null.");

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
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null; 
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      print("Disposing previous camera controller before initializing a new one.");
      await _stopCameraStream(); 
      await _cameraController!.dispose(); 
      _cameraController = null; 
    }
     if (mounted) setState(() => _isCameraInitialized = false); 

    print("Initializing camera: ${cameraDescription.name} with lens direction ${cameraDescription.lensDirection}");
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.high, 
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 
          : ImageFormatGroup.bgra8888, 
    );

    try {
      await _cameraController!.initialize();
      print("Camera initialized. Preview size: ${_cameraController!.value.previewSize}, Aspect Ratio: ${_cameraController!.value.aspectRatio}");
      
      await _startCameraStream(); 

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _cameraIndex = widget.cameras.indexOf(cameraDescription);
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
      await _cameraController!.startImageStream(_processCameraImage); 
      print("Camera image stream started.");
    } catch (e, stacktrace) {
      print('****** Exception on startCameraStream: $e');
      print(stacktrace);
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('카메라 스트림 시작 오류.')),
        );
      }
    }
  }

  Future<void> _stopCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized || !_cameraController!.value.isStreamingImages) {
      return;
    }
    try {
      await _cameraController!.stopImageStream();
      print("Camera image stream stopped.");
    } catch (e, stacktrace) {
      print('****** Exception on stopCameraStream: $e');
      print(stacktrace);
    } finally { 
      if(mounted) { 
        _isBusy = false;
        _isWaitingForRotation = false;
        _isWaitingForDetection = false;
        _pendingImageDataBytes = null;
      }
    }
  }

  void _processCameraImage(CameraImage image) {
    if (!mounted || _isBusy || _imageRotationIsolateSendPort == null) {
      return;
    }
    _isBusy = true; 
    _isWaitingForRotation = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
      _pendingImageDataWidth = image.width;
      _pendingImageDataHeight = image.height;
      _pendingImageDataFormatRaw = image.format.raw; 
      _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

      final camera = widget.cameras[_cameraIndex];
      final orientation = MediaQuery.of(context).orientation; 
      final DeviceOrientation deviceRotation = (orientation == Orientation.landscape)
          ? (Platform.isIOS ? DeviceOrientation.landscapeRight : DeviceOrientation.landscapeLeft) 
          : DeviceOrientation.portraitUp;

      final Map<String, dynamic> rotationPayload = {
        'sensorOrientation': camera.sensorOrientation,
        'deviceOrientationIndex': deviceRotation.index, 
      };
      _imageRotationIsolateSendPort!.send(rotationPayload); 
    } catch (e, stacktrace) {
      print("****** Error preparing image for rotation isolate: $e");
      print(stacktrace);
      _pendingImageDataBytes = null; 
      _isWaitingForRotation = false;
      _isBusy = false; 
    }
  }

  void _switchCamera() {
    if (widget.cameras.length < 2 || _isBusy) return; 
    print("Switching camera...");
    final newIndex = (_cameraIndex + 1) % widget.cameras.length;
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
              onPressed: _isBusy ? null : _switchCamera, 
            ),
        ],
      ),
      body: SafeArea( 
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized)
              Center( 
                child: AspectRatio(
                  aspectRatio: _cameraController!.value.aspectRatio,
                  child: cameraPreviewWidget,
                ),
              )
            else
              Center(child: cameraPreviewWidget), 

            if (_isCameraInitialized && _detectedObjects.isNotEmpty && _lastImageSize != null && _imageRotation != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  return CustomPaint(
                    size: constraints.biggest, 
                    painter: ObjectPainter(
                      objects: _detectedObjects,
                      imageSize: _lastImageSize!, 
                      screenSize: constraints.biggest, 
                      rotation: _imageRotation!,
                      cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
                    ),
                  );
                }
              ),

            // "처리 중..." 오버레이 표시 로직 제거
            // if (_isBusy && _isCameraInitialized) 
            //   Container(
            //     color: Colors.black.withOpacity(0.5),
            //     child: const Center(
            //       child: Column(
            //         mainAxisSize: MainAxisSize.min,
            //         children: [
            //           CircularProgressIndicator(color: Colors.white),
            //           SizedBox(height: 8),
            //           Text("처리 중...", style: TextStyle(color: Colors.white, fontSize: 16)),
            //         ],
            //       )
            //     ),
            //   ),
          ],
        ),
      ),
    );
  }
}