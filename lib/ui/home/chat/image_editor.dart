import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:image/image.dart' as img;

import '../../../bloc/subscribe_mixin.dart';
import '../../../constants/resources.dart';
import '../../../utils/extension/extension.dart';
import '../../../utils/file.dart';
import '../../../utils/hook.dart';
import '../../../utils/logger.dart';
import '../../../widgets/action_button.dart';
import '../../../widgets/dialog.dart';
import '../../../widgets/menu.dart';
import '../../../widgets/toast.dart';

Future<void> showImageEditor(
  BuildContext context, {
  required String path,
}) async {
  await showDialog(
    context: context,
    builder: (context) => _ImageEditorDialog(path: path),
  );
}

class _ImageEditorDialog extends HookWidget {
  const _ImageEditorDialog({
    Key? key,
    required this.path,
  }) : super(key: key);

  final String path;

  @override
  Widget build(BuildContext context) {
    final boundaryKey = useMemoized(() => GlobalKey());
    final image = useMemoizedFuture<ui.Image?>(() async {
      final bytes = File(path).readAsBytesSync();
      final codec = await PaintingBinding.instance.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    }, null, keys: [path]);
    if (image.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    final uiImage = image.data;
    if (uiImage == null) {
      assert(false, 'image is null');
      return const SizedBox();
    }
    return BlocProvider<_ImageEditorBloc>(
      create: (BuildContext context) =>
          _ImageEditorBloc(path: path, image: uiImage),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          color: context.theme.background.withOpacity(0.8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                const SizedBox(height: 56),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => _Preview(
                      path: path,
                      viewPortSize: constraints.biggest,
                      boundaryKey: boundaryKey,
                      image: uiImage,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const _OperationButtons(),
                const SizedBox(height: 56),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CustomDrawLine extends Equatable {
  const CustomDrawLine(this.path, this.color, this.width, this.eraser);

  final Path path;
  final Color color;
  final double width;
  final bool eraser;

  @override
  List<Object?> get props => [path, color, width, eraser];
}

enum DrawMode { none, brush, eraser }

class ImageEditorSnapshot {
  ImageEditorSnapshot({
    required this.imageRotate,
    required this.flip,
    required this.customDrawLines,
    required this.cropRect,
    required this.rawImagePath,
    required this.imagePath,
  });

  final _ImageRotate imageRotate;
  final bool flip;
  final List<CustomDrawLine> customDrawLines;
  final Rect cropRect;
  final String rawImagePath;
  final String imagePath;
}

class _ImageEditorState extends Equatable with EquatableMixin {
  const _ImageEditorState({
    required this.rotate,
    required this.flip,
    required this.drawLines,
    required this.drawColor,
    required this.drawMode,
    required this.canRedo,
    required this.cropRect,
  });

  final _ImageRotate rotate;

  final bool flip;

  final DrawMode drawMode;

  final List<CustomDrawLine> drawLines;

  /// Crop area of the image. zero means no crop.
  final Rect cropRect;

  final Color drawColor;

  final bool canRedo;

  bool get canReset => rotate != _ImageRotate.none;

  @override
  List<Object?> get props => [
        rotate,
        flip,
        drawLines,
        drawColor,
        drawMode,
        canRedo,
        cropRect,
      ];

  _ImageEditorState copyWith({
    _ImageRotate? rotate,
    bool? flip,
    List<CustomDrawLine>? drawLines,
    Color? drawColor,
    DrawMode? drawMode,
    bool? canRedo,
    Rect? cropRect,
  }) =>
      _ImageEditorState(
        rotate: rotate ?? this.rotate,
        flip: flip ?? this.flip,
        drawLines: drawLines ?? this.drawLines,
        drawColor: drawColor ?? this.drawColor,
        drawMode: drawMode ?? this.drawMode,
        canRedo: canRedo ?? this.canRedo,
        cropRect: cropRect ?? this.cropRect,
      );
}

class _ImageEditorBloc extends Cubit<_ImageEditorState> with SubscribeMixin {
  _ImageEditorBloc({
    required this.path,
    required this.image,
  }) : super(_ImageEditorState(
          rotate: _ImageRotate.none,
          flip: false,
          drawLines: const [],
          drawColor: _kDefaultDrawColor,
          drawMode: DrawMode.none,
          canRedo: false,
          cropRect: Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
        ));

  final String path;

  final ui.Image image;

  Path? _currentDrawingLine;

  final List<CustomDrawLine> _customDrawLines = [];

  // backup for cancel when clicked "cancel" button instead of "done"
  final List<CustomDrawLine> _backupDrawLines = [];

  //backup for redo.
  final List<CustomDrawLine> _redoDrawLines = [];

  final double _drawStrokeWidth = 11;

  void rotate() {
    _ImageRotate next() {
      switch (state.rotate) {
        case _ImageRotate.none:
          return _ImageRotate.quarter;
        case _ImageRotate.quarter:
          return _ImageRotate.half;
        case _ImageRotate.half:
          return _ImageRotate.threeQuarter;
        case _ImageRotate.threeQuarter:
          return _ImageRotate.none;
      }
    }

    emit(state.copyWith(rotate: next()));
  }

  void flip() {
    emit(state.copyWith(flip: !state.flip));
  }

  void enterDrawMode(DrawMode mode) {
    _backupDrawLines
      ..clear()
      ..addAll(_customDrawLines);
    emit(state.copyWith(drawMode: mode));
  }

  void exitDrawingMode({bool applyTempDraw = false}) {
    if (applyTempDraw) {
      _backupDrawLines.clear();
    } else {
      _customDrawLines
        ..clear()
        ..addAll(_backupDrawLines);
      _backupDrawLines.clear();
      _notifyCustomDrawUpdated();
    }
    emit(state.copyWith(drawMode: DrawMode.none));
  }

  void startDrawEvent(Offset position) {
    if (state.drawMode == DrawMode.none) {
      return;
    }
    _redoDrawLines.clear();
    _currentDrawingLine = Path()..moveTo(position.dx, position.dy);
    _notifyCustomDrawUpdated();
  }

  void updateDrawEvent(Offset position) {
    if (state.drawMode == DrawMode.none) {
      return;
    }
    assert(_currentDrawingLine != null, 'Drawing line is null');
    if (_currentDrawingLine == null) {
      return;
    }
    _currentDrawingLine!.lineTo(position.dx, position.dy);
    _notifyCustomDrawUpdated();
  }

  void endDrawEvent() {
    if (state.drawMode == DrawMode.none) {
      return;
    }
    final path = _currentDrawingLine;
    assert(path != null, 'Drawing line is null');
    if (path == null) {
      return;
    }
    final line = CustomDrawLine(
      path,
      state.drawColor,
      _drawStrokeWidth,
      state.drawMode == DrawMode.eraser,
    );
    _currentDrawingLine = null;
    _customDrawLines.add(line);
    _notifyCustomDrawUpdated();
  }

  void _notifyCustomDrawUpdated() {
    emit(state.copyWith(
      drawLines: [
        ..._customDrawLines,
        if (_currentDrawingLine != null)
          CustomDrawLine(
            Path.from(_currentDrawingLine!),
            state.drawColor,
            _drawStrokeWidth,
            state.drawMode == DrawMode.eraser,
          ),
      ],
      canRedo: _redoDrawLines.isNotEmpty,
    ));
  }

  void setCustomDrawColor(Color color) {
    emit(state.copyWith(drawColor: color));
  }

  void redoDraw() {
    if (state.drawMode == DrawMode.none) {
      return;
    }
    if (_redoDrawLines.isEmpty) {
      return;
    }
    final line = _redoDrawLines.removeLast();
    _customDrawLines.add(line);
    _notifyCustomDrawUpdated();
  }

  void undoDraw() {
    if (state.drawMode == DrawMode.none) {
      return;
    }
    if (_customDrawLines.isEmpty) {
      return;
    }
    final line = _customDrawLines.removeLast();
    _redoDrawLines.add(line);
    _notifyCustomDrawUpdated();
  }

  void setCropRatio(double? ratio) {
    if (ratio == null) {
      emit(state.copyWith(
        cropRect: Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        ),
      ));
      return;
    }
    final width =
        math.min(image.width.toDouble(), image.height.toDouble() * ratio);
    final height = width / ratio;
    final x = (image.width.toDouble() - width) / 2;
    final y = (image.height.toDouble() - height) / 2;
    emit(state.copyWith(
      cropRect: Rect.fromLTWH(x, y, width, height),
    ));
  }

  Future<Uint8List?> _flipAndRotateImage(ui.Image image) async {
    final bytes = await image.toBytes();
    if (bytes == null) {
      return null;
    }
    var imgImage = img.Image.fromBytes(image.width, image.height, bytes);

    if (state.flip) {
      img.flipHorizontal(imgImage);
    }
    if (state.rotate != _ImageRotate.none) {
      imgImage = img.copyRotate(imgImage, 360 - state.rotate.degree);
    }
    final data = img.PngEncoder().encodeImage(imgImage);
    return Uint8List.fromList(data);
  }

  Future<ImageEditorSnapshot?> takeSnapshot() async {
    final recorder = ui.PictureRecorder();

    final cropRect = !state.cropRect.isEmpty && !state.cropRect.isInfinite
        ? state.cropRect
        : null;

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final center = imageSize.center(Offset.zero);

    final canvas = Canvas(recorder)
      ..clipRect(Rect.fromLTWH(0, 0, imageSize.width, imageSize.height));

    if (cropRect != null) {
      canvas.translate(-cropRect.left, -cropRect.top);
    }

    final imageRect = Rect.fromCenter(
      center: center,
      width: image.width.toDouble(),
      height: image.height.toDouble(),
    );
    paintImage(
      canvas: canvas,
      rect: Rect.fromCenter(
        center: center,
        width: image.width.toDouble(),
        height: image.height.toDouble(),
      ),
      image: image,
    );

    canvas
      ..saveLayer(imageRect, Paint())
      ..translate(imageRect.left, imageRect.top);
    for (final line in _customDrawLines) {
      final paint = Paint()
        ..color = line.eraser ? Colors.white : line.color
        ..strokeWidth = line.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = line.eraser ? BlendMode.clear : BlendMode.srcOver
        ..isAntiAlias = true;
      canvas.drawPath(line.path, paint);
    }
    canvas.restore();

    final picture = recorder.endRecording();
    final ui.Image snapshotImage;
    if (cropRect != null) {
      snapshotImage = await picture.toImage(
        cropRect.width.round(),
        cropRect.height.round(),
      );
    } else {
      snapshotImage = await picture.toImage(
        imageSize.width.round(),
        imageSize.height.round(),
      );
    }

    final Uint8List? bytes;

    if (!state.flip && state.rotate == _ImageRotate.none) {
      bytes = await snapshotImage.toBytes(format: ui.ImageByteFormat.png);
    } else {
      bytes = await _flipAndRotateImage(snapshotImage);
    }
    if (bytes == null) {
      e('failed to convert image to bytes');
      return null;
    }
    // Save the image to the device's local storage.
    final file = await saveBytesToTempFile(bytes, 'image_edit', '.png');
    if (file == null) {
      e('failed to save image to file');
      return null;
    }
    d('save editor snapshot image to file: $file');
    return ImageEditorSnapshot(
      customDrawLines: _customDrawLines,
      imageRotate: state.rotate,
      flip: state.flip,
      cropRect: state.cropRect,
      rawImagePath: path,
      imagePath: file.path,
    );
  }

  void setCropRect(Rect cropRect) {
    emit(state.copyWith(cropRect: cropRect));
  }
}

class _Preview extends HookWidget {
  const _Preview({
    Key? key,
    required this.path,
    required this.viewPortSize,
    required this.boundaryKey,
    required this.image,
  }) : super(key: key);

  final String path;

  final Size viewPortSize;

  final Key boundaryKey;

  final ui.Image image;

  @override
  Widget build(BuildContext context) {
    final isFlip =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
      converter: (state) => state.flip,
    );

    final rotate = useBlocStateConverter<_ImageEditorBloc, _ImageEditorState,
        _ImageRotate>(
      converter: (state) => state.rotate,
    );

    final drawMode =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, DrawMode>(
      converter: (state) => state.drawMode,
    );

    final transformedViewPortSize = rotate.apply(viewPortSize);
    final scale = math.min<double>(
        math.min(transformedViewPortSize.width / image.width,
            transformedViewPortSize.height / image.height),
        1);

    final scaledImageSize = Size(image.width * scale, image.height * scale);

    return SizedBox(
      width: viewPortSize.width,
      height: viewPortSize.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Transform.rotate(
              transformHitTests: false,
              angle: -rotate.radius,
              child: RepaintBoundary(
                key: boundaryKey,
                child: Transform(
                  alignment: Alignment.center,
                  transform:
                      isFlip ? Matrix4.rotationY(math.pi) : Matrix4.identity(),
                  transformHitTests: false,
                  child: RepaintBoundary(
                    child: _CustomDrawingWidget(
                      viewPortSize: viewPortSize,
                      image: image,
                      rotate: rotate,
                      flip: isFlip,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (drawMode == DrawMode.none)
            Center(
              child: SizedBox.fromSize(
                size: rotate.apply(scaledImageSize),
                child: _CropRectWidget(
                  scaledImageSize: scaledImageSize,
                  isFlip: isFlip,
                  rotate: rotate,
                  scale: scale,
                ),
              ),
            )
        ],
      ),
    );
  }
}

extension _RectExt on Rect {
  Rect ensureInside(Rect rect) => Rect.fromLTRB(
        math.max(rect.left, left),
        math.max(rect.top, top),
        math.min(rect.right, right),
        math.min(rect.bottom, bottom),
      );

  Rect ensureShiftInside(Rect rect) {
    assert(width <= rect.width, 'width is greater than rect width');
    assert(height <= rect.height, 'height is greater than rect height');

    var offsetX = 0.0;
    if (left < rect.left) {
      offsetX = rect.left - left;
    } else if (right > rect.right) {
      offsetX = rect.right - right;
    }
    var offsetY = 0.0;
    if (top < rect.top) {
      offsetY = rect.top - top;
    } else if (bottom > rect.bottom) {
      offsetY = rect.bottom - bottom;
    }
    return translate(offsetX, offsetY);
  }

  Rect scaled(double scale) => Rect.fromLTRB(
        left * scale,
        top * scale,
        right * scale,
        bottom * scale,
      );

  Rect flipHorizontalInParent(Rect parent, bool flip) {
    if (!flip) {
      return this;
    }
    return Rect.fromLTRB(
        parent.width - right, top, parent.width - left, bottom);
  }
}

Rect transformInsideRect(Rect rect, Rect parent, double radius) {
  final center = parent.center;
  final rotateImageRect = Rect.fromPoints(
    _rotate(parent.topLeft, center, radius),
    _rotate(parent.bottomRight, center, radius),
  );

  final topLeft = _rotate(rect.topLeft, center, radius);
  final bottomRight = _rotate(rect.bottomRight, center, radius);
  final transformed = Rect.fromPoints(topLeft, bottomRight);
  return transformed.translate(-rotateImageRect.left, -rotateImageRect.top);
}

class _CropRectWidget extends HookWidget {
  const _CropRectWidget({
    Key? key,
    required this.scaledImageSize,
    required this.isFlip,
    required this.rotate,
    required this.scale,
  }) : super(key: key);

  final Size scaledImageSize;
  final bool isFlip;
  final _ImageRotate rotate;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final cropRect =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, Rect>(
      converter: (state) => state.cropRect,
    );

    final transformedRect = useMemoized(() {
      if (cropRect.isEmpty || cropRect.isInfinite) {
        return Rect.fromLTRB(
            0, 0, scaledImageSize.width, scaledImageSize.height);
      }
      final rawImageRect = Offset.zero & (scaledImageSize / scale);
      return transformInsideRect(
        cropRect.flipHorizontalInParent(rawImageRect, isFlip),
        rawImageRect,
        -rotate.radius,
      ).scaled(scale);
    }, [cropRect, scale, scaledImageSize, rotate, isFlip]);

    final trackingRectCorner = useRef<_ImageDragArea?>(null);

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onPanStart: (details) {
            final offset = details.localPosition;
            const cornerSize = 30.0;

            if (!transformedRect.contains(offset)) {
              trackingRectCorner.value = null;
              return;
            }
            if (offset.dx < transformedRect.left + cornerSize &&
                offset.dy < transformedRect.top + cornerSize) {
              trackingRectCorner.value = _ImageDragArea.topLeft;
            } else if (offset.dx > transformedRect.right - cornerSize &&
                offset.dy < transformedRect.top + cornerSize) {
              trackingRectCorner.value = _ImageDragArea.topRight;
            } else if (offset.dx < transformedRect.left + cornerSize &&
                offset.dy > transformedRect.bottom - cornerSize) {
              trackingRectCorner.value = _ImageDragArea.bottomLeft;
            } else if (offset.dx > transformedRect.right - cornerSize &&
                offset.dy > transformedRect.bottom - cornerSize) {
              trackingRectCorner.value = _ImageDragArea.bottomRight;
            } else {
              trackingRectCorner.value = _ImageDragArea.center;
            }
          },
          onPanUpdate: (details) {
            final corner = trackingRectCorner.value;
            if (corner == null) {
              return;
            }
            final delta = details.delta;
            final imageRect = Offset.zero & rotate.apply(scaledImageSize);
            Rect cropRect;
            switch (corner) {
              case _ImageDragArea.topLeft:
                cropRect = Rect.fromPoints(
                  transformedRect.topLeft + delta,
                  transformedRect.bottomRight,
                ).ensureInside(imageRect);
                break;
              case _ImageDragArea.topRight:
                cropRect = Rect.fromPoints(
                  transformedRect.bottomLeft,
                  transformedRect.topRight + delta,
                ).ensureInside(imageRect);
                break;
              case _ImageDragArea.bottomLeft:
                cropRect = Rect.fromPoints(
                  transformedRect.bottomLeft + delta,
                  transformedRect.topRight,
                ).ensureInside(imageRect);
                break;
              case _ImageDragArea.bottomRight:
                cropRect = Rect.fromPoints(
                  transformedRect.topLeft,
                  transformedRect.bottomRight + delta,
                ).ensureInside(imageRect);
                break;
              case _ImageDragArea.center:
                cropRect =
                    transformedRect.shift(delta).ensureShiftInside(imageRect);
                break;
            }

            if (cropRect.isEmpty) {
              return;
            }
            final rect = transformInsideRect(
                    cropRect.flipHorizontalInParent(imageRect, isFlip),
                    imageRect,
                    rotate.radius)
                .scaled(1 / scale);
            context.read<_ImageEditorBloc>().setCropRect(rect);
          },
          onPanEnd: (details) {
            trackingRectCorner.value = null;
          },
          child: CustomPaint(
            painter: _CropShadowOverlayPainter(
              cropRect: transformedRect,
              overlayColor: Colors.black.withOpacity(0.4),
              lineColor: Colors.white,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _CropShadowOverlayPainter extends CustomPainter {
  _CropShadowOverlayPainter({
    required this.cropRect,
    required this.overlayColor,
    required this.lineColor,
  });

  final Rect cropRect;
  final Color overlayColor;
  final Color lineColor;
  final double lineWidth = 1;

  final double cornerHandleWidth = 4;
  final double cornerHandleSize = 30;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    final paint = Paint()
      ..color = overlayColor
      ..style = PaintingStyle.fill;
    canvas
      ..drawRect(Offset.zero & size, paint)
      ..drawRect(cropRect, paint..blendMode = BlendMode.clear)
      ..restore();

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = lineWidth
      ..style = PaintingStyle.stroke;
    canvas
      ..drawRect(cropRect, linePaint)
      ..drawLine(
        Offset(cropRect.left + cropRect.width / 3, cropRect.top),
        Offset(cropRect.left + cropRect.width / 3, cropRect.bottom),
        linePaint,
      )
      ..drawLine(
        Offset(cropRect.left, cropRect.top + cropRect.height / 3),
        Offset(cropRect.right, cropRect.top + cropRect.height / 3),
        linePaint,
      )
      ..drawLine(
        Offset(cropRect.left, cropRect.top + cropRect.height * 2 / 3),
        Offset(cropRect.right, cropRect.top + cropRect.height * 2 / 3),
        linePaint,
      )
      ..drawLine(
        Offset(cropRect.left + cropRect.width * 2 / 3, cropRect.top),
        Offset(cropRect.left + cropRect.width * 2 / 3, cropRect.bottom),
        linePaint,
      );

    final cornerHandlePaint = Paint()
      ..color = lineColor
      ..strokeWidth = cornerHandleWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.fill;
    canvas
      // left top
      ..drawLine(
        cropRect.topLeft,
        cropRect.topLeft.translate(0, cornerHandleSize),
        cornerHandlePaint,
      )
      ..drawLine(
        cropRect.topLeft,
        cropRect.topLeft.translate(cornerHandleSize, 0),
        cornerHandlePaint,
      )
      // right top
      ..drawLine(
        cropRect.topRight,
        cropRect.topRight.translate(0, cornerHandleSize),
        cornerHandlePaint,
      )
      ..drawLine(
        cropRect.topRight,
        cropRect.topRight.translate(-cornerHandleSize, 0),
        cornerHandlePaint,
      )
      // left bottom
      ..drawLine(
        cropRect.bottomLeft,
        cropRect.bottomLeft.translate(0, -cornerHandleSize),
        cornerHandlePaint,
      )
      ..drawLine(
        cropRect.bottomLeft,
        cropRect.bottomLeft.translate(cornerHandleSize, 0),
        cornerHandlePaint,
      )
      // right bottom
      ..drawLine(
        cropRect.bottomRight,
        cropRect.bottomRight.translate(0, -cornerHandleSize),
        cornerHandlePaint,
      )
      ..drawLine(
        cropRect.bottomRight,
        cropRect.bottomRight.translate(-cornerHandleSize, 0),
        cornerHandlePaint,
      );
  }

  @override
  bool shouldRepaint(covariant _CropShadowOverlayPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect ||
      oldDelegate.overlayColor != overlayColor ||
      oldDelegate.lineColor != lineColor;
}

class _CustomDrawingWidget extends HookWidget {
  const _CustomDrawingWidget({
    Key? key,
    required this.viewPortSize,
    required this.image,
    required this.rotate,
    required this.flip,
  }) : super(key: key);

  final ui.Size viewPortSize;
  final ui.Image image;
  final _ImageRotate rotate;
  final bool flip;

  @override
  Widget build(BuildContext context) {
    final transformedViewPortSize = rotate.apply(viewPortSize);
    final scale = math.min<double>(
        math.min(transformedViewPortSize.width / image.width,
            transformedViewPortSize.height / image.height),
        1);

    final scaledImageSize = Size(image.width * scale, image.height * scale);

    final editorBloc = context.read<_ImageEditorBloc>();

    final lines = useBlocStateConverter<_ImageEditorBloc, _ImageEditorState,
        List<CustomDrawLine>>(
      bloc: editorBloc,
      converter: (state) => state.drawLines,
    );

    Offset screenToImage(Offset position) {
      final center = viewPortSize.center(Offset.zero);
      final radius = rotate.radius;
      var transformedX = (position.dx - center.dx) * math.cos(radius) -
          (position.dy - center.dy) * math.sin(radius) +
          center.dx;
      final transformedY = (position.dx - center.dx) * math.sin(radius) +
          (position.dy - center.dy) * math.cos(radius) +
          center.dy;

      if (flip) {
        transformedX = viewPortSize.width - transformedX;
      }
      final imageTopLeft = center.translate(
          -scaledImageSize.width / 2, -scaledImageSize.height / 2);

      final transformed = Offset(
          transformedX - imageTopLeft.dx, transformedY - imageTopLeft.dy);
      return transformed / scale;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) {
        editorBloc.startDrawEvent(screenToImage(details.localPosition));
      },
      onPanUpdate: (details) {
        editorBloc.updateDrawEvent(screenToImage(details.localPosition));
      },
      onPanEnd: (details) => editorBloc.endDrawEvent(),
      child: OverflowBox(
        maxWidth: scaledImageSize.width,
        maxHeight: scaledImageSize.height,
        child: CustomPaint(
          size: scaledImageSize,
          painter: _DrawerPainter(
            image: image,
            lines: lines,
            scale: scale,
          ),
        ),
      ),
    );
  }
}

enum _ImageDragArea {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  center,
}

enum _ImageRotate {
  none,
  quarter,
  half,
  threeQuarter,
}

extension _ImageRotateExt on _ImageRotate {
  double get radius {
    switch (this) {
      case _ImageRotate.none:
        return 0;
      case _ImageRotate.quarter:
        return math.pi / 2;
      case _ImageRotate.half:
        return math.pi;
      case _ImageRotate.threeQuarter:
        return 3 * math.pi / 2;
    }
  }

  double get degree {
    switch (this) {
      case _ImageRotate.none:
        return 0;
      case _ImageRotate.quarter:
        return 90;
      case _ImageRotate.half:
        return 180;
      case _ImageRotate.threeQuarter:
        return 270;
    }
  }

  Size apply(Size size) {
    if (!_boundRotated) {
      return size;
    }
    return Size(size.height, size.width);
  }

  bool get _boundRotated {
    switch (this) {
      case _ImageRotate.none:
        return false;
      case _ImageRotate.quarter:
      case _ImageRotate.threeQuarter:
        return true;
      case _ImageRotate.half:
        return false;
    }
  }
}

Offset _rotate(Offset position, Offset center, double radius) => Offset(
      (position.dx - center.dx) * math.cos(radius) -
          (position.dy - center.dy) * math.sin(radius) +
          center.dx,
      (position.dx - center.dx) * math.sin(radius) +
          (position.dy - center.dy) * math.cos(radius) +
          center.dy,
    );

class _DrawerPainter extends CustomPainter {
  _DrawerPainter({
    required this.image,
    required this.lines,
    required this.scale,
  });

  final ui.Image image;

  final List<CustomDrawLine> lines;

  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image);

    canvas
      ..saveLayer(Offset.zero & size, Paint())
      ..clipRect(Offset.zero & size)
      ..translate(0, 0)
      ..scale(scale);
    for (final line in lines) {
      final paint = Paint()
        ..color = line.eraser ? Colors.white : line.color
        ..strokeWidth = line.width * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = line.eraser ? BlendMode.clear : BlendMode.srcOver
        ..isAntiAlias = true;
      canvas.drawPath(line.path, paint);
    }
    canvas.restore();
  }

  @override
  bool? hitTest(ui.Offset position) => true;

  @override
  bool shouldRepaint(covariant _DrawerPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.lines != lines ||
      oldDelegate.scale != scale;
}

class _DrawColorSelector extends StatelessWidget {
  const _DrawColorSelector({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 38,
        child: Material(
          color: context.theme.chatBackground,
          borderRadius: BorderRadius.circular(62),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 2),
              // TODO custom color selector
              for (final color in _kPresetColors) _ColorTile(color: color),
              const SizedBox(width: 2),
            ],
          ),
        ),
      );
}

const _kPresetColors = [
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFF8E8E93),
  Color(0xFFE84D3D),
  Color(0xFFF8CD3E),
  Color(0xFF64D34F),
  Color(0xFF3077FF),
  Color(0xFFAC68DE),
];

const _kDefaultDrawColor = Color(0xFFE84D3D);

class _ColorTile extends HookWidget {
  const _ColorTile({Key? key, required this.color}) : super(key: key);

  final Color color;

  @override
  Widget build(BuildContext context) {
    final currentColor =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, Color>(
      converter: (state) => state.drawColor,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkResponse(
        radius: 24,
        onTap: () {
          context.read<_ImageEditorBloc>().setCustomDrawColor(color);
        },
        child: SizedBox(
          width: 28,
          height: 28,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (currentColor == color)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: context.theme.accent, width: 2),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              Center(
                child: SizedBox.square(
                  dimension: 21,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class _OperationButtons extends HookWidget {
  const _OperationButtons({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final drawMode =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, DrawMode>(
      converter: (state) => state.drawMode,
    );
    return Column(
      children: [
        if (drawMode != DrawMode.none)
          const _DrawColorSelector()
        else
          const SizedBox(height: 38),
        const SizedBox(height: 8),
        if (drawMode != DrawMode.none)
          const _DrawOperationBar()
        else
          const _NormalOperationBar(),
      ],
    );
  }
}

class _NormalOperationBar extends HookWidget {
  const _NormalOperationBar({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final imageEditorBloc = context.read<_ImageEditorBloc>();

    final rotated =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
      converter: (state) => state.rotate != _ImageRotate.none,
    );
    final flipped =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
      converter: (state) => state.flip,
    );
    final hasCustomDraw =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
      converter: (state) => state.drawLines.isNotEmpty,
    );
    final hasCrop =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
            converter: (state) {
      final width = imageEditorBloc.image.width;
      final height = imageEditorBloc.image.height;
      return state.cropRect.width.round() != width ||
          state.cropRect.height.round() != height;
    });
    return Material(
      borderRadius: BorderRadius.circular(8),
      color: context.theme.stickerPlaceholderColor,
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () {
                Navigator.maybePop(context);
              },
              child: Text(
                context.l10n.cancel,
                style: TextStyle(color: context.theme.text),
              ),
            ),
            ActionButton(
              color: rotated ? context.theme.accent : context.theme.icon,
              name: Resources.assetsImagesEditImageRotateSvg,
              onTap: imageEditorBloc.rotate,
            ),
            const SizedBox(width: 4),
            ActionButton(
              color: flipped ? context.theme.accent : context.theme.icon,
              name: Resources.assetsImagesEditImageFlipSvg,
              onTap: imageEditorBloc.flip,
            ),
            const SizedBox(width: 4),
            ContextMenuPortalEntry(
              interactiveForTap: true,
              buildMenus: () => [
                ContextMenu(
                  title: context.l10n.originalImage,
                  onTap: () => imageEditorBloc.setCropRatio(null),
                ),
                ContextMenu(
                  title: '1:1',
                  onTap: () => imageEditorBloc.setCropRatio(1),
                ),
                ContextMenu(
                  title: '2:3',
                  onTap: () => imageEditorBloc.setCropRatio(2 / 3),
                ),
                ContextMenu(
                  title: '3:2',
                  onTap: () => imageEditorBloc.setCropRatio(3 / 2),
                ),
                ContextMenu(
                  title: '3:4',
                  onTap: () => imageEditorBloc.setCropRatio(3 / 4),
                ),
                ContextMenu(
                  title: '4:3',
                  onTap: () => imageEditorBloc.setCropRatio(4 / 3),
                ),
                ContextMenu(
                  title: '9:16',
                  onTap: () => imageEditorBloc.setCropRatio(9 / 16),
                ),
                ContextMenu(
                  title: '16:9',
                  onTap: () => imageEditorBloc.setCropRatio(16 / 9),
                ),
              ],
              child: ActionButton(
                interactive: false,
                color: hasCrop ? context.theme.accent : context.theme.icon,
                name: Resources.assetsImagesEditImageClipSvg,
              ),
            ),
            const SizedBox(width: 4),
            ActionButton(
              color: hasCustomDraw ? context.theme.accent : context.theme.icon,
              name: Resources.assetsImagesEditImageDrawSvg,
              onTap: () {
                context.read<_ImageEditorBloc>().enterDrawMode(DrawMode.brush);
              },
            ),
            TextButton(
              onPressed: () async {
                showToastLoading(context);
                final snapshot =
                    await context.read<_ImageEditorBloc>().takeSnapshot();
                if (snapshot == null) {
                  await showToastFailed(context, null);
                  return;
                }
                showToastSuccessful(context);
                await showMixinDialog(
                  context: context,
                  child: Image.file(
                    File(snapshot.imagePath),
                    fit: BoxFit.cover,
                  ),
                );
                // await Navigator.maybePop(context, snapshot);
              },
              child: Text(context.l10n.done),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawOperationBar extends HookWidget {
  const _DrawOperationBar({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final drawMode =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, DrawMode>(
      converter: (state) => state.drawMode,
    );
    final canRedo =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
      converter: (state) => state.canRedo,
    );
    final canUndo =
        useBlocStateConverter<_ImageEditorBloc, _ImageEditorState, bool>(
      converter: (state) => state.drawLines.isNotEmpty,
    );
    return Material(
      borderRadius: BorderRadius.circular(8),
      color: context.theme.stickerPlaceholderColor,
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () {
                context.read<_ImageEditorBloc>().exitDrawingMode();
              },
              child: Text(
                context.l10n.cancel,
                style: TextStyle(color: context.theme.text),
              ),
            ),
            ActionButton(
              color: canUndo
                  ? context.theme.icon
                  : context.theme.icon.withOpacity(0.2),
              name: Resources.assetsImagesEditImageUndoSvg,
              onTap: () {
                context.read<_ImageEditorBloc>().undoDraw();
              },
            ),
            const SizedBox(width: 4),
            ActionButton(
              color: canRedo
                  ? context.theme.icon
                  : context.theme.icon.withOpacity(0.2),
              name: Resources.assetsImagesEditImageRedoSvg,
              onTap: () {
                context.read<_ImageEditorBloc>().redoDraw();
              },
            ),
            const SizedBox(width: 4),
            ActionButton(
              color: drawMode == DrawMode.brush
                  ? context.theme.accent
                  : context.theme.icon,
              name: Resources.assetsImagesEditImageDrawSvg,
              onTap: () {
                context.read<_ImageEditorBloc>().enterDrawMode(DrawMode.brush);
              },
            ),
            ActionButton(
              color: drawMode == DrawMode.eraser
                  ? context.theme.accent
                  : context.theme.icon,
              name: Resources.assetsImagesEditImageEraseSvg,
              onTap: () {
                context.read<_ImageEditorBloc>().enterDrawMode(DrawMode.eraser);
              },
            ),
            TextButton(
              onPressed: () {
                context
                    .read<_ImageEditorBloc>()
                    .exitDrawingMode(applyTempDraw: true);
              },
              child: Text(context.l10n.done),
            ),
          ],
        ),
      ),
    );
  }
}
