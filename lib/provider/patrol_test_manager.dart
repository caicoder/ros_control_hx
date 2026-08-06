import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/page/patrol_test_page.dart';
import 'package:ros_flutter_gui_app/provider/ros_channel.dart';
import 'package:ros_flutter_gui_app/service/online_player.dart';
import 'package:ros_flutter_gui_app/service/navigation_log_manager.dart';

/// 全局单例巡逻测试管理与进度监听器
class PatrolTestManager extends ChangeNotifier {
  // 单例模式 (Singleton Pattern)
  static final PatrolTestManager _instance = PatrolTestManager._internal();
  factory PatrolTestManager() => _instance;
  static PatrolTestManager get instance => _instance;
  PatrolTestManager._internal();

  // 配置项
  int totalRounds = 1;
  int currentRound = 0;
  int currentPointIndex = 0;
  int totalPointsInRound = 0;
  
  // 运行状态
  bool isPatrolling = false;
  bool shouldStop = false;
  
  // 实时计时
  int elapsedSeconds = 0;
  Timer? _tickerTimer;

  // 目标点与日志
  NavPoint? currentTargetPoint;
  PatrolPointLog? activePointLog;
  final List<PatrolPointLog> liveLogs = [];
  PatrolReport? currentReport;

  Set<String> selectedPointNames = {};
  List<NavPoint> availablePoints = [];

  // ================= 实时进度计算属性 =================
  /// 选中的总点位数
  int get selectedPointsCount => selectedPointNames.length;

  /// 本次巡逻任务的总点位交互次数 (遍数 * 选中点数)
  int get totalPointsToPatrol => totalRounds * selectedPointsCount;

  /// 已处理完成的点位数
  int get completedPointsCount {
    if (!isPatrolling && liveLogs.isEmpty) return 0;
    return liveLogs.where((log) => log.status != 'Navigating').length;
  }

  /// 成功到达的点位数
  int get successPointsCount {
    return liveLogs.where((log) => log.status == 'Finished').length;
  }

  /// 异常/失败的点位数
  int get failedPointsCount {
    return liveLogs.where((log) => log.status == 'Error' || log.status == 'Failed' || log.status == 'Timeout').length;
  }

  /// 总体完成进度比例 (0.0 ~ 1.0)
  double get overallProgress {
    if (totalPointsToPatrol <= 0) return 0.0;
    final ratio = completedPointsCount / totalPointsToPatrol;
    return ratio.clamp(0.0, 1.0);
  }

  /// 总体完成进度百分比文本 (如 "75%")
  String get progressPercentText {
    return '${(overallProgress * 100).toStringAsFixed(0)}%';
  }

  /// 格式化的运行总时间 (如 "02:15")
  String get formattedElapsedTime {
    final m = (elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ================= 点位与参数配置 =================
  void setAvailablePoints(List<NavPoint> points) {
    availablePoints = List.from(points);
    if (selectedPointNames.isEmpty) {
      selectedPointNames = points.map((p) => p.name).toSet();
    }
    notifyListeners();
  }

  void togglePointSelection(String name) {
    if (selectedPointNames.contains(name)) {
      selectedPointNames.remove(name);
    } else {
      selectedPointNames.add(name);
    }
    notifyListeners();
  }

  void selectAllPoints() {
    selectedPointNames = availablePoints.map((p) => p.name).toSet();
    notifyListeners();
  }

  void deselectAllPoints() {
    selectedPointNames.clear();
    notifyListeners();
  }

  void setTotalRounds(int rounds) {
    if (rounds >= 1) {
      totalRounds = rounds;
      notifyListeners();
    }
  }

  // ================= 巡逻进程驱动逻辑 (核心单例进程) =================
  /// 启动自动巡逻测试
  Future<void> startPatrol(RosChannel rosChannel) async {
    final pointsToPatrol = availablePoints.where((p) => selectedPointNames.contains(p.name)).toList();
    if (pointsToPatrol.isEmpty || isPatrolling) return;

    isPatrolling = true;
    shouldStop = false;
    currentRound = 0;
    currentPointIndex = 0;
    totalPointsInRound = pointsToPatrol.length;
    elapsedSeconds = 0;
    liveLogs.clear();
    activePointLog = null;

    // 启动秒级计时器
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isPatrolling) {
        elapsedSeconds++;
        notifyListeners();
      }
    });

    currentReport = PatrolReport(
      id: 'patrol_${DateTime.now().millisecondsSinceEpoch}',
      ip: rosChannel.currentIp,
      startTime: DateTime.now(),
      totalRounds: totalRounds,
    );
    notifyListeners();

    for (int round = 1; round <= totalRounds; round++) {
      if (shouldStop) break;

      currentRound = round;
      currentReport?.completedRounds = round;
      notifyListeners();

      for (int i = 0; i < pointsToPatrol.length; i++) {
        if (shouldStop) break;

        currentPointIndex = i + 1;
        final targetPoint = pointsToPatrol[i];
        currentTargetPoint = targetPoint;

        final triggerTime = DateTime.now();
        final taskId = 'task_patrol_r${round}_p${i}_${triggerTime.millisecondsSinceEpoch}';

        final logItem = PatrolPointLog(
          pointName: targetPoint.name,
          pointType: targetPoint.type,
          x: targetPoint.x,
          y: targetPoint.y,
          yaw: targetPoint.theta,
          roundIndex: round,
          triggerTime: triggerTime,
          status: 'Navigating',
        );

        activePointLog = logItem;
        liveLogs.add(logItem);
        notifyListeners();

        // 记录导航日志头部: ==== 导航开始: [点位名称] ====
        await NavigationLogManager.instance.logNavStart(targetPoint.name);

        // 重置上次状态，标示开始新点位导航
        rosChannel.movebaseActionStatusData.value = {
          "movebaseActionRobotStatus": "ActionStatusRunning",
          "errormessage": "",
          "timestamp": DateTime.now().millisecondsSinceEpoch.toString(),
        };

        Completer<void> pointCompleter = Completer<void>();
        late VoidCallback statusListener;

        void checkStatus() {
          if (pointCompleter.isCompleted) return;

          final statusData = rosChannel.movebaseActionStatusData.value;
          final status = statusData['movebaseActionRobotStatus'] ?? '';
          final errStr = statusData['errormessage'] ?? '';

          print("==== PATROL CHECK STATUS: status=$status, errStr=$errStr ====");

          if (status == 'ActionStatusFinished') {
            logItem.status = 'Finished';
            logItem.errorMessage = '';
            logItem.finishTime = DateTime.now();
            currentReport?.pointLogs.add(logItem);
            
            pointCompleter.complete();
          } else if (status == 'ActionStatusError') {
            logItem.status = 'Error';
            logItem.errorMessage = errStr.isNotEmpty ? errStr : 'ActionStatusError';
            logItem.finishTime = DateTime.now();
            currentReport?.pointLogs.add(logItem);

            // 语音播报：错误信息
            String voiceText = "导航失败，未知原因";
            if (errStr == 'target_in_obs') {
              voiceText = "导航失败，目标点在障碍物中";
            } else if (errStr == 'robot_in_obs') {
              voiceText = "导航失败，机器人在障碍物中";
            }
            try {
              OnlinePlayer.instance.playTTS(voiceText);
            } catch (e) {
              print("TTS 播报异常 (忽略): $e");
            }

            pointCompleter.complete();
          } else if (status == 'ActionStatusStopped') {
            logItem.status = 'Cancelled';
            logItem.errorMessage = '用户终止';
            logItem.finishTime = DateTime.now();
            currentReport?.pointLogs.add(logItem);

            // 语音播报：取消停止
            try {
              OnlinePlayer.instance.playTTS("导航任务已取消");
            } catch (e) {
              print("TTS 播报异常 (忽略): $e");
            }

            pointCompleter.complete();
          }
        }

        statusListener = () => checkStatus();
        rosChannel.movebaseActionStatusData.addListener(statusListener);

        // 1. 发送 /navigation 服务请求 (具备 busy 重试机制)
        Map<String, dynamic> resp = {};
        String resultStr = 'busy';

        for (int retry = 0; retry < 4; retry++) {
          if (shouldStop) break;

          resp = await rosChannel.sendNavigationServiceGoal(
            taskId: taskId,
            requestType: 'robot_move_to_pose',
            x: targetPoint.x,
            y: targetPoint.y,
            yaw: targetPoint.theta,
          );

          resultStr = resp['result']?.toString() ?? 'error';

          if (resultStr == 'ok') {
            break;
          } else if (resultStr == 'busy' && retry < 3) {
            print("==== ROS导航服务繁忙 (busy)，等待 1.5 秒后进行第 ${retry + 1} 次重试... ====");
            await Future.delayed(const Duration(milliseconds: 1500));
          } else {
            break;
          }
        }

        // 2. 判断服务响应：若非 "ok"，记为失败并触发下一个点位
        if (resultStr != 'ok') {
          rosChannel.movebaseActionStatusData.removeListener(statusListener);
          logItem.status = 'Failed';
          logItem.errorMessage = resultStr;
          logItem.finishTime = DateTime.now();
          currentReport?.pointLogs.add(logItem);
          activePointLog = null;
          notifyListeners();
          continue;
        }

        // 立即评估一次当前状态 (防止在服务返回前 topic 消息已就绪)
        checkStatus();

        await pointCompleter.future;
        rosChannel.movebaseActionStatusData.removeListener(statusListener);

        activePointLog = null;
        notifyListeners();

        // 触发到达或结束后的 3秒 间隔延迟
        if (!shouldStop && (round < totalRounds || i < pointsToPatrol.length - 1)) {
          for (int secondsLeft = 3; secondsLeft > 0; secondsLeft--) {
            if (shouldStop) break;
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
    }

    _tickerTimer?.cancel();

    final report = currentReport;
    if (report != null) {
      report.endTime = DateTime.now();
      report.isCompleted = !shouldStop;
      await PatrolReportStorage.saveReport(report);
    }

    isPatrolling = false;
    activePointLog = null;
    currentTargetPoint = null;
    notifyListeners();
  }

  /// 停止巡逻进程
  void stopPatrol(RosChannel rosChannel) {
    shouldStop = true;
    _tickerTimer?.cancel();
    rosChannel.sendNavigationServiceGoal(
      taskId: 'cancel_${DateTime.now().millisecondsSinceEpoch}',
      requestType: 'cancelGoal',
      x: 0,
      y: 0,
      yaw: 0,
    );
    notifyListeners();
  }
}
