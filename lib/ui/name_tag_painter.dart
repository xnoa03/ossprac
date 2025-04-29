// lib/ui/name_tag_painter.dart
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart'; // Label

class NameTagUtils {
  // 네임태그 그리기 함수
  static void paintNameTag({
    required Canvas canvas,
    required Label label,
    required Rect boundingBoxRect, // 기준 박스 위치
    required Size canvasSize,
  }) {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(
        text: ' ${label.text} (${(label.confidence * 100).toStringAsFixed(0)}%) ',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.0,
          backgroundColor: Colors.black54,
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout(minWidth: 0, maxWidth: canvasSize.width);

    // 텍스트 위치 계산 및 조정
    double textY = boundingBoxRect.top - textPainter.height;
    if (textY < 0) {
      textY = boundingBoxRect.top + 2;
      if (textY + textPainter.height > canvasSize.height) {
        textY = boundingBoxRect.bottom - textPainter.height - 2;
      }
    }
    final Offset textOffset = Offset(boundingBoxRect.left, textY.clamp(0.0, canvasSize.height - textPainter.height));

    // 텍스트 그리기
    textPainter.paint(canvas, textOffset);
  }
}