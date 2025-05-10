// lib/ui/object_painter.dart
import 'dart:ui' as ui; // ui.Image 사용 위함 (현재 코드에서는 직접 사용 안 함)
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:camera/camera.dart'; // CameraLensDirection

class ObjectPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize; // ML Kit이 처리한 원본 이미지의 크기 (회전 전 기준)
  final Size screenSize; // CustomPaint 위젯이 그려지는 실제 화면상의 크기
  final InputImageRotation rotation; // ML Kit 처리 시 사용된 이미지 회전
  final CameraLensDirection cameraLensDirection;

  ObjectPainter({
    required this.objects,
    required this.imageSize,
    required this.screenSize,
    required this.rotation,
    required this.cameraLensDirection,
  });

  @override
  void paint(Canvas canvas, Size size) { // 여기서 size는 screenSize와 동일 (LayoutBuilder에서 전달)
    if (imageSize.isEmpty || size.isEmpty) {
      // print("ObjectPainter: imageSize or size is empty. Skipping paint.");
      return;
    }

    final Paint paintRect = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 // 테두리 두께 조정
      ..color = Colors.lightGreenAccent; // 색상 변경

    final Paint backgroundPaint = Paint()..color = Colors.black.withOpacity(0.6); // 투명도 조절
    // final Paint textPaint = Paint()..color = Colors.white; // TextSpan 스타일에서 직접 지정


    for (final DetectedObject detectedObject in objects) {
      // print("ObjectPainter: Painting object ${detectedObject.labels.firstOrNull?.text}");
      final Rect boundingBox = detectedObject.boundingBox; // 이미지 기준 좌표 (LTWH)

      // 1. 이미지 회전에 따른 실제 이미지 크기 조정 (ML Kit 좌표계 기준)
      // ML Kit은 회전된 이미지에 대해 좌표를 반환하지만, 여기서 imageSize는 회전 전 원본 크기.
      // Painter는 회전된 카메라 프리뷰 위에 그리므로, 회전을 고려하여 스케일링해야 함.
      final bool IsImageRotatedSideways = rotation == InputImageRotation.rotation90deg ||
                                      rotation == InputImageRotation.rotation270deg;

      final double originalImageWidth = IsImageRotatedSideways ? imageSize.height : imageSize.width;
      final double originalImageHeight = IsImageRotatedSideways ? imageSize.width : imageSize.height;

      // 2. 화면(CustomPaint 위젯)과 원본 이미지 간의 스케일 비율 계산
      // CameraPreview는 AspectRatio 위젯 내에 있으므로, 화면을 채우도록 스케일링됨 (BoxFit.cover 유사 효과)
      final double scaleX = size.width / originalImageWidth;
      final double scaleY = size.height / originalImageHeight;

      // BoxFit.cover와 유사하게 동작한다고 가정할 때,
      // 화면 비율과 이미지 비율 중 작은 쪽을 기준으로 전체 스케일 결정.
      // 이렇게 하면 이미지가 화면에 꽉 차고, 일부는 잘릴 수 있음.
      final double scale = (originalImageWidth / originalImageHeight > size.width / size.height)
          ? size.height / originalImageHeight // 이미지의 세로에 화면을 맞춤 (좌우가 잘릴 수 있음)
          : size.width / originalImageWidth;   // 이미지의 가로에 화면을 맞춤 (상하가 잘릴 수 있음)

      // 스케일링된 이미지 크기
      final double scaledImageWidth = originalImageWidth * scale;
      final double scaledImageHeight = originalImageHeight * scale;

      // 화면 중앙에 이미지가 위치하도록 오프셋 계산
      final double offsetX = (size.width - scaledImageWidth) / 2.0;
      final double offsetY = (size.height - scaledImageHeight) / 2.0;


      // 3. 바운딩 박스 좌표를 스케일링 및 오프셋 적용하여 변환
      // ML Kit이 반환하는 boundingBox는 회전이 적용된 이미지 기준의 좌표임.
      // Painter는 회전되지 않은(세로로 긴) 화면 위에 그리므로, InputImageRotation 값을 사용해야 함.

      Rect displayRect;

      // 좌표 변환: ML Kit의 좌표계(회전된 이미지의 좌상단이 원점) -> 화면 좌표계(CustomPaint의 좌상단이 원점)
      // 전면 카메라인 경우 좌우 반전도 고려.
      // 이 변환은 매우 중요하며, 많은 테스트와 조정이 필요합니다.
      // 다음은 일반적인 접근 방식의 예시입니다.
      // (0,0) (w,0)
      // (0,h) (w,h)

      double l, t, r, b;

      switch (rotation) {
        case InputImageRotation.rotation0deg:
          l = boundingBox.left * scale + offsetX;
          t = boundingBox.top * scale + offsetY;
          r = boundingBox.right * scale + offsetX;
          b = boundingBox.bottom * scale + offsetY;
          if (cameraLensDirection == CameraLensDirection.front) {
            // 전면카메라 좌우반전
            final double tempL = l;
            l = size.width - r;
            r = size.width - tempL;
          }
          break;
        case InputImageRotation.rotation90deg:
          // 이미지의 top -> 화면의 left (x)
          // 이미지의 right (width - left) -> 화면의 top (y)
          l = boundingBox.top * scale + offsetX;
          t = (originalImageWidth - boundingBox.right) * scale + offsetY; // imageSize.width는 회전 전. originalImageWidth 사용
          r = boundingBox.bottom * scale + offsetX;
          b = (originalImageWidth - boundingBox.left) * scale + offsetY;
          if (cameraLensDirection == CameraLensDirection.front) {
            // 90도 회전 시 전면 카메라는 상하 반전처럼 보일 수 있음
            // 또는 x축 기준 미러링
            final double tempT = t;
            t = size.height - b;
            b = size.height - tempT;
          }
          break;
        case InputImageRotation.rotation180deg:
          l = (originalImageWidth - boundingBox.right) * scale + offsetX;
          t = (originalImageHeight - boundingBox.bottom) * scale + offsetY;
          r = (originalImageWidth - boundingBox.left) * scale + offsetX;
          b = (originalImageHeight - boundingBox.top) * scale + offsetY;
          if (cameraLensDirection == CameraLensDirection.front) {
             // 180도 회전 시 전면 카메라는 다시 좌우반전 (원본 대비)
            final double tempL = l;
            l = size.width - r;
            r = size.width - tempL;
          }
          break;
        case InputImageRotation.rotation270deg:
          // 이미지의 bottom (height - top) -> 화면의 left(x)
          // 이미지의 left -> 화면의 top(y)
          l = (originalImageHeight - boundingBox.bottom) * scale + offsetX;
          t = boundingBox.left * scale + offsetY;
          r = (originalImageHeight - boundingBox.top) * scale + offsetX;
          b = boundingBox.right * scale + offsetY;
           if (cameraLensDirection == CameraLensDirection.front) {
            // 270도 회전 시 전면 카메라는 상하 반전처럼 보일 수 있음 (90도와 유사)
            // 또는 x축 기준 미러링
            final double tempT = t;
            t = size.height - b;
            b = size.height - tempT;
          }
          break;
      }
      displayRect = Rect.fromLTRB(l, t, r, b);

      // 화면 경계 클리핑 (선택 사항, 박스가 화면 밖으로 나가는 것을 방지)
      // displayRect = displayRect.intersect(Rect.fromLTWH(0, 0, size.width, size.height));
      // if (displayRect.isEmpty) continue;


      canvas.drawRect(displayRect, paintRect);

      // 레이블 그리기
      if (detectedObject.labels.isNotEmpty) {
        final label = detectedObject.labels.first;
        final TextSpan span = TextSpan(
          text: '${label.text} (${(label.confidence * 100).toStringAsFixed(1)}%)',
          style: const TextStyle(color: Colors.white, fontSize: 14.0, fontWeight: FontWeight.bold),
        );
        final TextPainter tp = TextPainter(
          text: span,
          textAlign: TextAlign.left,
          textDirection: TextDirection.ltr,
        );
        tp.layout();

        // 텍스트 배경
        final Rect textBackgroundRect = Rect.fromLTWH(
            displayRect.left,
            displayRect.top - tp.height - 4, // 박스 위에 표시
            tp.width + 8,
            tp.height + 4);
        canvas.drawRect(textBackgroundRect, backgroundPaint);
        // 텍스트
        tp.paint(canvas, Offset(displayRect.left + 4, displayRect.top - tp.height -2)); // 배경 중앙에 오도록 약간 조정
      }
    }
  }

  @override
  bool shouldRepaint(covariant ObjectPainter oldDelegate) {
    // 객체 목록, 이미지 크기, 화면 크기, 회전, 카메라 방향 중 하나라도 변경되면 다시 그림
    return oldDelegate.objects != objects ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.screenSize != screenSize || // screenSize 추가
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}