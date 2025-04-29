// lib/ui/bounding_box_painter.dart
import 'dart:io'; // Platform
import 'package:flutter/material.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart'; // InputImageRotation
import 'package:camera/camera.dart'; // CameraLensDirection

class BoundingBoxUtils {
  // 화면 좌표 계산 함수
  static Rect scaleAndTranslateRect({
    required Rect boundingBox,         // ML Kit 결과의 원본 박스
    required Size imageSize,           // 원본 이미지 크기
    required Size canvasSize,          // 그림을 그릴 캔버스 크기
    required InputImageRotation rotation, // 이미지 회전
    required CameraLensDirection cameraLensDirection, // 카메라 렌즈 방향 (미러링용)
  }) {
    final double imageWidth = imageSize.width;
    final double imageHeight = imageSize.height;
    final double canvasWidth = canvasSize.width;
    final double canvasHeight = canvasSize.height;

    // 스케일 계산
    final double scaleX, scaleY;
    if (_isRotationSideways(rotation)) {
      scaleX = canvasWidth / imageHeight;
      scaleY = canvasHeight / imageWidth;
    } else {
      scaleX = canvasWidth / imageWidth;
      scaleY = canvasHeight / imageHeight;
    }

    // 좌표 변환
    double L, T, R, B;
    switch (rotation) {
      case InputImageRotation.rotation90deg: L = boundingBox.top * scaleX; T = (imageWidth - boundingBox.right) * scaleY; R = boundingBox.bottom * scaleX; B = (imageWidth - boundingBox.left) * scaleY; break;
      case InputImageRotation.rotation180deg: L = (imageWidth - boundingBox.right) * scaleX; T = (imageHeight - boundingBox.bottom) * scaleY; R = (imageWidth - boundingBox.left) * scaleX; B = (imageHeight - boundingBox.top) * scaleY; break;
      case InputImageRotation.rotation270deg: L = (imageHeight - boundingBox.bottom) * scaleX; T = boundingBox.left * scaleY; R = (imageHeight - boundingBox.top) * scaleX; B = boundingBox.right * scaleY; break;
      case InputImageRotation.rotation0deg: default: L = boundingBox.left * scaleX; T = boundingBox.top * scaleY; R = boundingBox.right * scaleX; B = boundingBox.bottom * scaleY; break;
    }

    // 미러링
    if (cameraLensDirection == CameraLensDirection.front && Platform.isAndroid) {
      double tempL = L; L = canvasWidth - R; R = canvasWidth - tempL;
    }

    // 범위 제한 및 보정
    L = L.clamp(0.0, canvasWidth); T = T.clamp(0.0, canvasHeight); R = R.clamp(0.0, canvasWidth); B = B.clamp(0.0, canvasHeight);
    if (L > R) { double temp = L; L = R; R = temp; } if (T > B) { double temp = T; T = B; B = temp; }

    return Rect.fromLTRB(L, T, R, B);
  }

  // 바운딩 박스 그리기 함수
  static void paintBoundingBox(Canvas canvas, Rect rect) {
    final Paint paintRect = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    if (rect.width > 0 && rect.height > 0) {
      canvas.drawRect(rect, paintRect);
    }
  }

  // 내부 헬퍼 함수
  static bool _isRotationSideways(InputImageRotation rotation) {
   return rotation == InputImageRotation.rotation90deg ||
       rotation == InputImageRotation.rotation270deg;
  }
}