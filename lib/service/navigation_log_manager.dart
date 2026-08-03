import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 导航日志管理器：实时日志显示与本地日志文件存储
class NavigationLogManager extends ChangeNotifier {
  static final NavigationLogManager _instance = NavigationLogManager._internal();
  factory NavigationLogManager() => _instance;
  static NavigationLogManager get instance => _instance;

  NavigationLogManager._internal() {
    _initLogFile();
  }

  final List<String> logs = [];
  File? _logFile;
  String? _logFilePath;

  String? get logFilePath => _logFilePath;

  Future<void> _initLogFile() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      _logFilePath = '${docDir.path}/navigation_status.log';
      _logFile = File(_logFilePath!);
      if (!await _logFile!.exists()) {
        await _logFile!.create(recursive: true);
      }
      print("==== 导航日志文件存储路径: $_logFilePath ====");
    } catch (e) {
      print("初始化日志文件失败: $e");
    }
  }

  /// 1. 记录导航开始 (带点位名称，换行打印)
  Future<void> logNavStart(String pointName) async {
    final timestamp = _formatTimestamp();
    final logLine = "[$timestamp] ==== 导航开始: $pointName ====\n";
    await _addLog(logLine);
  }

  /// 2. 实时记录 /movebaseActionRobotStatus 话题全部回调数据
  Future<void> logTopicStatus(String status, String errorMessage, {dynamic rawData}) async {
    final timestamp = _formatTimestamp();
    String rawStr = "";
    if (rawData != null) {
      try {
        rawStr = rawData is String ? rawData : jsonEncode(rawData);
      } catch (_) {
        rawStr = rawData.toString();
      }
    }
    final logLine = "[$timestamp] Topic /movebaseActionRobotStatus -> status: '$status', errormessage: '$errorMessage' | 完整数据: $rawStr";
    await _addLog(logLine);
  }

  /// 写入内存列表并追加到本地日志文件
  Future<void> _addLog(String logLine) async {
    logs.insert(0, logLine);
    if (logs.length > 500) {
      logs.removeLast();
    }
    notifyListeners();

    try {
      if (_logFile != null) {
        await _logFile!.writeAsString('$logLine\n', mode: FileMode.append);
      }
    } catch (e) {
      print("写入日志文件异常: $e");
    }
  }

  /// 清空日志
  Future<void> clearLogs() async {
    logs.clear();
    notifyListeners();
    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.writeAsString('');
      }
    } catch (e) {
      print("清空日志文件异常: $e");
    }
  }

  String _formatTimestamp() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return "${now.year}-$m-$d $hh:$mm:$ss.$ms";
  }
}
