// lib/ui/object_painter.dart
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:camera/camera.dart';
import 'bounding_box_painter.dart'; // 바운딩 박스 유틸리티 임포트
import 'name_tag_painter.dart';   // 네임태그 유틸리티 임포트
import 'package:google_mlkit_commons/google_mlkit_commons.dart'; // InputImageRotation

class ObjectPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;

  ObjectPainter({
    required this.objects,
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.isEmpty) return;

    for (final DetectedObject detectedObject in objects) {
      // 1. 바운딩 박스 화면 좌표 계산
      final Rect canvasRect = BoundingBoxUtils.scaleAndTranslateRect(
        boundingBox: detectedObject.boundingBox,
        imageSize: imageSize,
        canvasSize: size,
        rotation: rotation,
        cameraLensDirection: cameraLensDirection,
      );

      // 2. 바운딩 박스 그리기 (위임)
      BoundingBoxUtils.paintBoundingBox(canvas, canvasRect);

      // 3. 네임태그 그리기 (위임)
      if (detectedObject.labels.isNotEmpty) {
        NameTagUtils.paintNameTag(
          canvas: canvas,
          label: detectedObject.labels.first,
          boundingBoxRect: canvasRect, // 계산된 박스 좌표 기준
          canvasSize: size,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant ObjectPainter oldDelegate) {
    // 필요한 경우 다시 그리도록 함
    return oldDelegate.objects != objects ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}