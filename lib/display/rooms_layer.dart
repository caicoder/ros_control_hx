import 'dart:math';
import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:ros_flutter_gui_app/provider/ros_channel.dart';

class RosRoom {
  final String id;
  final String name;
  final String description;
  final vm.Vector3 polygonPoint1;
  final vm.Vector3 polygonPoint2;
  final vm.Vector3 polygonPoint3;
  final vm.Vector3 polygonPoint4;
  final vm.Vector3 positionIn;
  final double yawIn;
  final vm.Vector3 positionOut;
  final double yawOut;
  final String type;
  final Color color;

  RosRoom({
    required this.id,
    required this.name,
    required this.description,
    required this.polygonPoint1,
    required this.polygonPoint2,
    required this.polygonPoint3,
    required this.polygonPoint4,
    required this.positionIn,
    required this.yawIn,
    required this.positionOut,
    required this.yawOut,
    required this.type,
    required this.color,
  });

  factory RosRoom.fromJson(Map<String, dynamic> json, Color color) {
    vm.Vector3 parsePoint(Map<String, dynamic>? p) {
      if (p == null) return vm.Vector3.zero();
      return vm.Vector3(
        (p['x'] as num?)?.toDouble() ?? 0.0,
        (p['y'] as num?)?.toDouble() ?? 0.0,
        (p['z'] as num?)?.toDouble() ?? 0.0,
      );
    }

    return RosRoom(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      polygonPoint1: parsePoint(json['polygon_point1']),
      polygonPoint2: parsePoint(json['polygon_point2']),
      polygonPoint3: parsePoint(json['polygon_point3']),
      polygonPoint4: parsePoint(json['polygon_point4']),
      positionIn: parsePoint(json['position_in']),
      yawIn: (json['yaw_in'] as num?)?.toDouble() ?? 0.0,
      positionOut: parsePoint(json['position_out']),
      yawOut: (json['yaw_out'] as num?)?.toDouble() ?? 0.0,
      type: json['type']?.toString() ?? '',
      color: color,
    );
  }
}

class RoomsLayerComponent extends Component {
  final RosChannel? rosChannel;
  List<RosRoom> _rooms = [];
  bool _showRooms = false;

  RoomsLayerComponent({this.rosChannel});

  void updateRooms(List<RosRoom> rooms, bool show) {
    _rooms = rooms;
    _showRooms = show;
  }

  @override
  void render(Canvas canvas) {
    if (!_showRooms || _rooms.isEmpty || rosChannel == null) return;
    final map = rosChannel!.map_.value;
    if (map.data.isEmpty || map.mapConfig.resolution <= 0) return;

    for (final room in _rooms) {
      // 1. Convert real world (meters) coordinates to map index coordinates
      final p1 = map.xy2idx(vm.Vector2(room.polygonPoint1.x, room.polygonPoint1.y));
      final p2 = map.xy2idx(vm.Vector2(room.polygonPoint2.x, room.polygonPoint2.y));
      final p3 = map.xy2idx(vm.Vector2(room.polygonPoint3.x, room.polygonPoint3.y));
      final p4 = map.xy2idx(vm.Vector2(room.polygonPoint4.x, room.polygonPoint4.y));

      final posIn = map.xy2idx(vm.Vector2(room.positionIn.x, room.positionIn.y));
      final posOut = map.xy2idx(vm.Vector2(room.positionOut.x, room.positionOut.y));

      // 2. Draw quadrilateral frame and fill
      final fillPaint = Paint()
        ..color = Colors.purple.withOpacity(0.25)
        ..style = PaintingStyle.fill;

      final borderPaint = Paint()
        ..color = Colors.purple
        ..strokeWidth = 4.0
        ..style = PaintingStyle.stroke;

      final path = Path()
        ..moveTo(p1.x, p1.y)
        ..lineTo(p2.x, p2.y)
        ..lineTo(p3.x, p3.y)
        ..lineTo(p4.x, p4.y)
        ..close();

      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, borderPaint);

      // 3. Draw in/out points & orientation arrows
      _drawArrow(canvas, posIn, -room.yawIn, Colors.green);
      _drawText(canvas, "进", posIn, Colors.green);

      _drawArrow(canvas, posOut, -room.yawOut, Colors.red);
      _drawText(canvas, "出", posOut, Colors.red);

      // 4. Draw room name in center of quadrilateral
      final center = (p1 + p2 + p3 + p4) / 4.0;
      _drawCenterText(canvas, room.name, center, room.color);
    }
  }

  void _drawArrow(Canvas canvas, vm.Vector2 center, double angle, Color color) {
    const double arrowLength = 3.0;
    const double arrowAngle = 30 * pi / 180;
    
    final start = Offset(center.x, center.y);
    final end = Offset(
      center.x + arrowLength * cos(angle),
      center.y + arrowLength * sin(angle),
    );
    
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 0.3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
      
    canvas.drawLine(start, end, paint);
    
    const double headLength = 1.0;
    final Offset leftBar = Offset(
      end.dx - headLength * cos(angle - arrowAngle),
      end.dy - headLength * sin(angle - arrowAngle),
    );
    final Offset rightBar = Offset(
      end.dx - headLength * cos(angle + arrowAngle),
      end.dy - headLength * sin(angle + arrowAngle),
    );
    canvas.drawLine(end, leftBar, paint);
    canvas.drawLine(end, rightBar, paint);
    
    final Paint startPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(start, 0.4, startPaint);
  }

  void _drawText(Canvas canvas, String text, vm.Vector2 position, Color color) {
    final textSpan = TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: 2.0,
        fontWeight: FontWeight.bold,
        shadows: const [
          Shadow(
            blurRadius: 1.0,
            color: Colors.black,
            offset: Offset(0.5, 0.5),
          ),
        ],
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(position.x - textPainter.width / 2, position.y - textPainter.height - 0.5),
    );
  }

  void _drawCenterText(Canvas canvas, String text, vm.Vector2 position, Color color) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 4.0,
        fontWeight: FontWeight.bold,
        shadows: [
          Shadow(
            blurRadius: 1.5,
            color: Colors.black,
            offset: Offset(0.5, 0.5),
          ),
        ],
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(position.x - textPainter.width / 2, position.y - textPainter.height / 2),
    );
  }
}
