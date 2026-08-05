import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/provider/nav_point_manager.dart';
import 'package:ros_flutter_gui_app/provider/ros_channel.dart';
import 'package:ros_flutter_gui_app/provider/patrol_test_manager.dart';
import 'package:ros_flutter_gui_app/service/navigation_log_manager.dart';
import 'package:ros_flutter_gui_app/service/report_exporter.dart';
import 'package:toastification/toastification.dart';
/// 单个点位巡逻记录
class PatrolPointLog {
  final String pointName;
  final String pointType;
  final double x;
  final double y;
  final double yaw;
  final int roundIndex; // 第几遍
  final DateTime triggerTime; // 触发时间点
  DateTime? finishTime; // 到达/完成时间点
  String status; // "Finished", "Error", "Failed", "Cancelled", "Timeout", "Navigating"
  String errorMessage; // target_in_obs, robot_in_obs, unknow, etc.

  PatrolPointLog({
    required this.pointName,
    required this.pointType,
    required this.x,
    required this.y,
    required this.yaw,
    required this.roundIndex,
    required this.triggerTime,
    this.finishTime,
    this.status = "Navigating",
    this.errorMessage = "",
  });

  int get durationMs => finishTime != null
      ? finishTime!.difference(triggerTime).inMilliseconds
      : 0;

  Map<String, dynamic> toJson() => {
        'pointName': pointName,
        'pointType': pointType,
        'x': x,
        'y': y,
        'yaw': yaw,
        'roundIndex': roundIndex,
        'triggerTime': triggerTime.toIso8601String(),
        'finishTime': finishTime?.toIso8601String(),
        'status': status,
        'errorMessage': errorMessage,
      };

  factory PatrolPointLog.fromJson(Map<String, dynamic> json) => PatrolPointLog(
        pointName: json['pointName'] ?? '',
        pointType: json['pointType'] ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0.0,
        y: (json['y'] as num?)?.toDouble() ?? 0.0,
        yaw: (json['yaw'] as num?)?.toDouble() ?? 0.0,
        roundIndex: json['roundIndex'] ?? 1,
        triggerTime: DateTime.parse(json['triggerTime']),
        finishTime: json['finishTime'] != null
            ? DateTime.parse(json['finishTime'])
            : null,
        status: json['status'] ?? '',
        errorMessage: json['errorMessage'] ?? '',
      );
}

/// 巡逻测试报告
class PatrolReport {
  final String id;
  final DateTime startTime;
  DateTime? endTime;
  final int totalRounds;
  int completedRounds;
  List<PatrolPointLog> pointLogs;
  bool isCompleted;

  PatrolReport({
    required this.id,
    required this.startTime,
    this.endTime,
    required this.totalRounds,
    this.completedRounds = 0,
    List<PatrolPointLog>? pointLogs,
    this.isCompleted = false,
  }) : pointLogs = pointLogs ?? [];

  int get totalPointsCount => pointLogs.length;
  int get successCount =>
      pointLogs.where((l) => l.status == 'Finished').length;
  int get failedCount =>
      pointLogs.where((l) => l.status == 'Error' || l.status == 'Failed' || l.status == 'Timeout').length;

  double get successRate =>
      totalPointsCount > 0 ? (successCount / totalPointsCount) * 100 : 0.0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'totalRounds': totalRounds,
        'completedRounds': completedRounds,
        'isCompleted': isCompleted,
        'pointLogs': pointLogs.map((l) => l.toJson()).toList(),
      };

  factory PatrolReport.fromJson(Map<String, dynamic> json) => PatrolReport(
        id: json['id'] ?? '',
        startTime: DateTime.parse(json['startTime']),
        endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
        totalRounds: json['totalRounds'] ?? 1,
        completedRounds: json['completedRounds'] ?? 0,
        isCompleted: json['isCompleted'] ?? false,
        pointLogs: (json['pointLogs'] as List? ?? [])
            .map((e) => PatrolPointLog.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 巡逻报告存储服务
class PatrolReportStorage {
  static const String _storageKey = 'patrol_test_reports_v1';

  static Future<List<PatrolReport>> loadReports() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final List list = jsonDecode(jsonStr);
      return list.map((e) => PatrolReport.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      print('加载巡逻报告失败: $e');
      return [];
    }
  }

  static Future<void> saveReport(PatrolReport report) async {
    final reports = await loadReports();
    reports.insert(0, report);
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(reports.map((r) => r.toJson()).toList());
    await prefs.setString(_storageKey, jsonStr);
  }

  static Future<void> deleteReport(String reportId) async {
    final reports = await loadReports();
    reports.removeWhere((r) => r.id == reportId);
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(reports.map((r) => r.toJson()).toList());
    await prefs.setString(_storageKey, jsonStr);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}

class PatrolTestPage extends StatefulWidget {
  const PatrolTestPage({Key? key}) : super(key: key);

  @override
  State<PatrolTestPage> createState() => _PatrolTestPageState();
}

class _PatrolTestPageState extends State<PatrolTestPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoadingPoints = false;
  
  // 历史报告
  List<PatrolReport> _historyReports = [];
  bool _isLoadingHistory = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadPoints();
    _loadHistoryReports();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 从 ROS / NavPointManager 加载所有点位
  Future<void> _loadPoints() async {
    setState(() {
      _isLoadingPoints = true;
    });

    try {
      final rosChannel = Provider.of<RosChannel>(context, listen: false);
      final points = await rosChannel.fetchMarkers();
      if (points.isNotEmpty) {
        Provider.of<NavPointManager>(context, listen: false).setNavPoints(points);
      }
    } catch (e) {
      print("拉取点位异常: $e");
    }

    final navPointManager = Provider.of<NavPointManager>(context, listen: false);
    final points = navPointManager.navPoints;

    final patrolManager = Provider.of<PatrolTestManager>(context, listen: false);
    patrolManager.setAvailablePoints(points);

    setState(() {
      _isLoadingPoints = false;
    });
  }

  /// 加载本地历史报告
  Future<void> _loadHistoryReports() async {
    if (mounted) {
      setState(() {
        _isLoadingHistory = true;
      });
    }
    final reports = await PatrolReportStorage.loadReports();
    if (mounted) {
      setState(() {
        _historyReports = reports;
        _isLoadingHistory = false;
      });
    }
  }

  /// 开始巡逻
  Future<void> _startPatrol() async {
    final patrolManager = Provider.of<PatrolTestManager>(context, listen: false);
    final rosChannel = Provider.of<RosChannel>(context, listen: false);

    if (patrolManager.selectedPointNames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请至少选择一个巡逻点位！'),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    await patrolManager.startPatrol(rosChannel);
    await _loadHistoryReports();
  }

  /// 停止巡逻
  void _stopPatrol() {
    final patrolManager = Provider.of<PatrolTestManager>(context, listen: false);
    final rosChannel = Provider.of<RosChannel>(context, listen: false);
    patrolManager.stopPatrol(rosChannel);
  }

  @override
  Widget build(BuildContext context) {
    const bgGradient = LinearGradient(
      colors: [Color(0xFF0F172A), Color(0xFF1E1B4B)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildModernHeader(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildConsoleTab(),
                    _buildHistoryTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶栏 Header
  Widget _buildModernHeader() {
    final patrolManager = Provider.of<PatrolTestManager>(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.8),
        border: const Border(bottom: BorderSide(color: Color(0xFF334155))),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF06B6D4).withOpacity(0.1),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF38BDF8), size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF06B6D4), Color(0xFF6366F1)],
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(color: Color(0xFF06B6D4), blurRadius: 10, spreadRadius: 1),
              ],
            ),
            child: const Icon(Icons.alt_route_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [Color(0xFF38BDF8), Color(0xFFA855F7), Color(0xFFF43F5E)],
            ).createShader(bounds),
            child: const Text(
              '巡逻自动化测试面板',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const Spacer(),
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              indicator: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF06B6D4), Color(0xFF3B82F6)],
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(color: Color(0xFF06B6D4), blurRadius: 8),
                ],
              ),
              labelColor: Colors.white,
              unselectedLabelColor: const Color(0xFF94A3B8),
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              tabs: const [
                Tab(icon: Icon(Icons.speed_rounded, size: 16), text: '巡逻控制台'),
                Tab(icon: Icon(Icons.analytics_rounded, size: 16), text: '巡逻报告与历史'),
              ],
            ),
          ),
          const SizedBox(width: 16),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF38BDF8)),
            tooltip: '重新刷新获取点位',
            onPressed: patrolManager.isPatrolling ? null : _loadPoints,
          ),
        ],
      ),
    );
  }

  // ================= 巡逻控制台 TAB =================
  Widget _buildConsoleTab() {
    final manager = Provider.of<PatrolTestManager>(context);

    return Row(
      children: [
        // 左侧控制与点位卡片
        Container(
          width: 380,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B).withOpacity(0.9),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 巡逻次数设置
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF334155).withOpacity(0.6),
                      const Color(0xFF1E293B).withOpacity(0.8),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.loop_rounded, color: Color(0xFF38BDF8), size: 20),
                        SizedBox(width: 8),
                        Text(
                          '循环巡逻次数:',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.5)),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove, color: Color(0xFF38BDF8), size: 18),
                            onPressed: manager.isPatrolling || manager.totalRounds <= 1
                                ? null
                                : () => manager.setTotalRounds(manager.totalRounds - 1),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF06B6D4), Color(0xFF3B82F6)],
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${manager.totalRounds} 遍',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add, color: Color(0xFF38BDF8), size: 18),
                            onPressed: manager.isPatrolling
                                ? null
                                : () => manager.setTotalRounds(manager.totalRounds + 1),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // 启动 / 停止 大按钮
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 8,
                    shadowColor: manager.isPatrolling
                        ? const Color(0xFFF43F5E).withOpacity(0.5)
                        : const Color(0xFF10B981).withOpacity(0.5),
                  ),
                  onPressed: manager.isPatrolling ? _stopPatrol : _startPatrol,
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: manager.isPatrolling
                            ? [const Color(0xFFF43F5E), const Color(0xFFE11D48)]
                            : [const Color(0xFF10B981), const Color(0xFF06B6D4)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Container(
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            manager.isPatrolling ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            manager.isPatrolling ? '停止巡逻测试' : '开始巡逻测试',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              if (manager.isPatrolling) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF06B6D4).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '巡逻测试运行中 (第 ${manager.currentRound} / ${manager.totalRounds} 遍)',
                        style: const TextStyle(
                          color: Color(0xFF38BDF8),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // 点位选择列表头
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.place_rounded, color: Color(0xFFA855F7), size: 18),
                      const SizedBox(width: 6),
                      Text(
                        '巡逻目标点位 (${manager.selectedPointNames.length}/${manager.availablePoints.length})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: manager.isPatrolling
                        ? null
                        : () {
                            if (manager.selectedPointNames.length == manager.availablePoints.length) {
                              manager.deselectAllPoints();
                            } else {
                              manager.selectAllPoints();
                            }
                          },
                    child: Text(
                      manager.selectedPointNames.length == manager.availablePoints.length ? '取消全选' : '全选点位',
                      style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 6),

              // 点位选择列表
              Expanded(
                child: _isLoadingPoints
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFF06B6D4)))
                    : manager.availablePoints.isEmpty
                        ? const Center(
                            child: Text(
                              '暂未获取到点位，请连接ROS后重试',
                              style: TextStyle(color: Color(0xFF94A3B8)),
                            ),
                          )
                        : ListView.builder(
                            itemCount: manager.availablePoints.length,
                            itemBuilder: (context, index) {
                              final point = manager.availablePoints[index];
                              final isSelected = manager.selectedPointNames.contains(point.name);
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: isSelected
                                        ? [
                                            const Color(0xFF1E293B),
                                            const Color(0xFF0F172A),
                                          ]
                                        : [
                                            const Color(0xFF0F172A).withOpacity(0.5),
                                            const Color(0xFF0F172A).withOpacity(0.5),
                                          ],
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF38BDF8)
                                        : const Color(0xFF334155),
                                    width: isSelected ? 1.5 : 1,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: const Color(0xFF38BDF8).withOpacity(0.15),
                                            blurRadius: 8,
                                          ),
                                        ]
                                      : [],
                                ),
                                child: CheckboxListTile(
                                  dense: true,
                                  value: isSelected,
                                  activeColor: const Color(0xFF06B6D4),
                                  checkColor: Colors.white,
                                  title: Row(
                                    children: [
                                      Text(
                                        point.name,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFA855F7).withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: const Color(0xFFA855F7).withOpacity(0.4)),
                                        ),
                                        child: Text(
                                          point.type,
                                          style: const TextStyle(
                                            color: Color(0xFFC084FC),
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(
                                    'X: ${point.x.toStringAsFixed(2)} | Y: ${point.y.toStringAsFixed(2)} | Yaw: ${point.theta.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF64748B),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  onChanged: manager.isPatrolling
                                      ? null
                                      : (val) {
                                          manager.togglePointSelection(point.name);
                                        },
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),

        // 右侧控制台日志
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withOpacity(0.8),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (manager.isPatrolling && manager.activePointLog != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1E1B4B), Color(0xFF312E81)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF6366F1), width: 1.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0xFF6366F1),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            color: Color(0xFF38BDF8),
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF06B6D4),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '第 ${manager.currentRound} / ${manager.totalRounds} 遍',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '目标点: ${manager.activePointLog!.pointName}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 17,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '触发时间: ${_formatTime(manager.activePointLog!.triggerTime)}  |  坐标: (${manager.activePointLog!.x.toStringAsFixed(2)}, ${manager.activePointLog!.y.toStringAsFixed(2)}, ${manager.activePointLog!.yaw.toStringAsFixed(2)})',
                                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF3B82F6), Color(0xFF06B6D4)],
                            ),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            '正在导航中...',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                DefaultTabController(
                  length: 2,
                  child: Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TabBar(
                          isScrollable: true,
                          indicatorColor: const Color(0xFF38BDF8),
                          labelColor: const Color(0xFF38BDF8),
                          unselectedLabelColor: const Color(0xFF94A3B8),
                          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          tabs: const [
                            Tab(icon: Icon(Icons.list_alt_rounded, size: 16), text: '巡逻点位明细'),
                            Tab(icon: Icon(Icons.terminal_rounded, size: 16), text: 'Topic 实时日志与文件'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: TabBarView(
                            children: [
                              // Tab 1: 点位明细列表
                              manager.liveLogs.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.directions_run_rounded, size: 64, color: const Color(0xFF334155)),
                                          const SizedBox(height: 12),
                                          const Text(
                                            '暂无巡逻点位明细',
                                            style: TextStyle(
                                              color: Color(0xFF94A3B8),
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: manager.liveLogs.length,
                                      itemBuilder: (context, index) {
                                        final log = manager.liveLogs[manager.liveLogs.length - 1 - index];
                                        return _buildVibrantLogCard(log);
                                      },
                                    ),

                              // Tab 2: ROS /movebaseActionRobotStatus 实时 Topic 日志与文件
                              ListenableBuilder(
                                listenable: NavigationLogManager.instance,
                                builder: (context, child) {
                                  final logManager = NavigationLogManager.instance;
                                  final logs = logManager.logs;

                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0F172A),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFF334155)),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.insert_drive_file_rounded, color: Color(0xFF38BDF8), size: 16),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                '日志文件: ${logManager.logFilePath ?? '初始化中...'}',
                                                style: const TextStyle(
                                                  color: Color(0xFF94A3B8),
                                                  fontSize: 11,
                                                  fontFamily: 'monospace',
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFF43F5E), size: 18),
                                              tooltip: '清空日志文件',
                                              onPressed: () => logManager.clearLogs(),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF090D16),
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.3)),
                                          ),
                                          child: logs.isEmpty
                                              ? const Center(
                                                  child: Text(
                                                    '等待接收 /movebaseActionRobotStatus 话题日志...',
                                                    style: TextStyle(color: Color(0xFF64748B), fontFamily: 'monospace', fontSize: 12),
                                                  ),
                                                )
                                              : ListView.builder(
                                                  itemCount: logs.length,
                                                  itemBuilder: (context, index) {
                                                    final line = logs[index];
                                                    final isHeader = line.contains('==== 导航开始:');
                                                    final isError = line.contains('[ERROR]');
                                                    Color textColor;
                                                    if (isHeader) {
                                                      textColor = const Color(0xFF38BDF8);
                                                    } else if (isError) {
                                                      textColor = const Color(0xFFF43F5E);
                                                    } else {
                                                      textColor = const Color(0xFF34D399);
                                                    }
                                                    
                                                    return Padding(
                                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                                      child: Text(
                                                        line,
                                                        style: TextStyle(
                                                          color: textColor,
                                                          fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
                                                          fontSize: 12,
                                                          fontFamily: 'monospace',
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ================= 巡逻历史报告 TAB =================
  Widget _buildHistoryTab() {
    if (_isLoadingHistory) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF06B6D4)));
    }

    if (_historyReports.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assessment_outlined, size: 80, color: const Color(0xFF334155)),
            const SizedBox(height: 16),
            const Text(
              '暂无历史巡逻测试报告',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.history_edu_rounded, color: Color(0xFFA855F7), size: 22),
                  const SizedBox(width: 8),
                  Text(
                    '历史巡逻报告列表 (${_historyReports.length} 份记录)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF38BDF8)),
                      foregroundColor: const Color(0xFF38BDF8),
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('导出报告', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: _historyReports.isEmpty ? null : () async {
                      toastification.show(
                        context: context,
                        title: const Text('正在导出报告...'),
                        type: ToastificationType.info,
                        autoCloseDuration: const Duration(seconds: 2),
                      );
                      
                      final path = await ReportExporter.exportToHtml(_historyReports);
                      if (path != null) {
                        toastification.show(
                          context: context,
                          title: const Text('导出成功'),
                          description: Text('报告已保存至: $path'),
                          type: ToastificationType.success,
                          autoCloseDuration: const Duration(seconds: 5),
                        );
                      } else {
                        toastification.show(
                          context: context,
                          title: const Text('导出失败'),
                          description: const Text('无法保存报告文件，请检查存储权限或稍后再试。'),
                          type: ToastificationType.error,
                          autoCloseDuration: const Duration(seconds: 3),
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFF43F5E)),
                      foregroundColor: const Color(0xFFF43F5E),
                    ),
                    icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                    label: const Text('清空历史报告', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF1E293B),
                          title: const Text('清空确认', style: TextStyle(color: Colors.white)),
                          content: const Text('确定要清空所有已保存的巡逻测试报告吗？', style: TextStyle(color: Color(0xFF94A3B8))),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8))),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('确定清空', style: TextStyle(color: Color(0xFFF43F5E))),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await PatrolReportStorage.clearAll();
                        await _loadHistoryReports();
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          Expanded(
            child: ListView.builder(
              itemCount: _historyReports.length,
              itemBuilder: (context, index) {
                final report = _historyReports[index];
                return _buildVibrantReportCard(report);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 炫彩日志卡片渲染
  Widget _buildVibrantLogCard(PatrolPointLog log) {
    Color badgeColor;
    Gradient cardGradient;
    IconData statusIcon;
    String statusText;

    switch (log.status) {
      case 'Finished':
        badgeColor = const Color(0xFF10B981);
        cardGradient = LinearGradient(
          colors: [const Color(0xFF064E3B).withOpacity(0.6), const Color(0xFF022C22).withOpacity(0.8)],
        );
        statusIcon = Icons.check_circle_rounded;
        statusText = '到达成功';
        break;
      case 'Error':
        badgeColor = const Color(0xFFF43F5E);
        cardGradient = LinearGradient(
          colors: [const Color(0xFF881337).withOpacity(0.6), const Color(0xFF4C0519).withOpacity(0.8)],
        );
        statusIcon = Icons.error_rounded;
        statusText = '导航错误 (${log.errorMessage})';
        break;
      case 'Failed':
        badgeColor = const Color(0xFFF59E0B);
        cardGradient = LinearGradient(
          colors: [const Color(0xFF78350F).withOpacity(0.6), const Color(0xFF451A03).withOpacity(0.8)],
        );
        statusIcon = Icons.warning_rounded;
        statusText = '服务拒绝 (${log.errorMessage})';
        break;
      case 'Timeout':
        badgeColor = const Color(0xFFA855F7);
        cardGradient = LinearGradient(
          colors: [const Color(0xFF581C87).withOpacity(0.6), const Color(0xFF3B0764).withOpacity(0.8)],
        );
        statusIcon = Icons.timer_off_rounded;
        statusText = '导航超时';
        break;
      case 'Cancelled':
        badgeColor = const Color(0xFF64748B);
        cardGradient = LinearGradient(
          colors: [const Color(0xFF1E293B).withOpacity(0.6), const Color(0xFF0F172A).withOpacity(0.8)],
        );
        statusIcon = Icons.cancel_rounded;
        statusText = '已手动取消';
        break;
      default:
        badgeColor = const Color(0xFF3B82F6);
        cardGradient = LinearGradient(
          colors: [const Color(0xFF1E3A8A).withOpacity(0.6), const Color(0xFF172554).withOpacity(0.8)],
        );
        statusIcon = Icons.navigation_rounded;
        statusText = '导航中...';
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        gradient: cardGradient,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: badgeColor.withOpacity(0.5)),
        boxShadow: [
          BoxShadow(
            color: badgeColor.withOpacity(0.1),
            blurRadius: 6,
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: badgeColor.withOpacity(0.2),
            shape: BoxShape.circle,
            border: Border.all(color: badgeColor),
          ),
          child: Icon(statusIcon, color: badgeColor, size: 20),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF06B6D4), Color(0xFF3B82F6)],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '第 ${log.roundIndex} 遍',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              log.pointName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Text(
              '(${log.pointType})',
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '坐标: (${log.x.toStringAsFixed(2)}, ${log.y.toStringAsFixed(2)}, ${log.yaw.toStringAsFixed(2)})',
                style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 2),
              Text(
                '触发时间: ${_formatTime(log.triggerTime)}${log.finishTime != null ? "  |  到达时间: ${_formatTime(log.finishTime!)} (耗时 ${(log.durationMs / 1000).toStringAsFixed(1)}s)" : ""}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: badgeColor.withOpacity(0.2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: badgeColor),
          ),
          child: Text(
            statusText,
            style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ),
      ),
    );
  }

  /// 炫彩历史报告卡片渲染
  Widget _buildVibrantReportCard(PatrolReport report) {
    final isSuccess = report.successRate >= 80;
    final themeColor = isSuccess ? const Color(0xFF10B981) : const Color(0xFFF59E0B);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: themeColor.withOpacity(0.4)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: themeColor.withOpacity(0.2),
            shape: BoxShape.circle,
            border: Border.all(color: themeColor),
          ),
          child: Icon(
            isSuccess ? Icons.verified_rounded : Icons.warning_amber_rounded,
            color: themeColor,
            size: 22,
          ),
        ),
        title: Text(
          '巡逻报告 - ${_formatDateTime(report.startTime)}',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
        ),
        subtitle: Text(
          '巡逻遍数: ${report.completedRounds}/${report.totalRounds}  |  成功率: ${report.successRate.toStringAsFixed(1)}% (${report.successCount}/${report.totalPointsCount})',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFF43F5E)),
          onPressed: () async {
            await PatrolReportStorage.deleteReport(report.id);
            await _loadHistoryReports();
          },
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatPill('总巡逻遍数', '${report.totalRounds} 遍', const Color(0xFF38BDF8)),
                    _buildStatPill('测试点位数', '${report.totalPointsCount} 次', const Color(0xFFA855F7)),
                    _buildStatPill('成功点位', '${report.successCount}', const Color(0xFF10B981)),
                    _buildStatPill('异常/失败', '${report.failedCount}', const Color(0xFFF43F5E)),
                  ],
                ),
                const Divider(height: 24, color: Color(0xFF334155)),
                const Text(
                  '点位记录明细:',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 8),
                ...report.pointLogs.map((log) => _buildVibrantLogCard(log)).toList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatPill(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        children: [
          Text(title, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color)),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${_formatTime(dt)}';
  }
}
