import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:provider/provider.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'package:ros_flutter_gui_app/provider/ros_channel.dart';
import 'package:ros_flutter_gui_app/provider/them_provider.dart';
import 'package:ros_flutter_gui_app/page/map_edit_flame.dart';
import 'package:ros_flutter_gui_app/provider/nav_point_manager.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/basic/topology_map.dart';

enum EditToolType {
  addNavPoint,
  drawObstacle,
  eraseObstacle,
}

class MapEditPage extends StatefulWidget {
  final VoidCallback? onExit;
  
  const MapEditPage({super.key, this.onExit});

  @override
  State<MapEditPage> createState() => _MapEditPageState();
}

class _MapEditPageState extends State<MapEditPage> {
  late MapEditFlame game;
  late GlobalState globalState;
  late RosChannel rosChannel;

  // 当前选中的编辑工具
  EditToolType? selectedTool;
  
  // 导航点列表
  List<NavPoint> navPoints = [];
  
  // 当前选中的点位信息
  NavPoint? selectedWayPointInfo;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    globalState = Provider.of<GlobalState>(context, listen: false);
    rosChannel = Provider.of<RosChannel>(context, listen: false);
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    
    // 设置地图编辑模式
    globalState.mode.value = Mode.mapEdit;

    // 创建专门的地图编辑Flame组件
    game = MapEditFlame(
      rosChannel: rosChannel,
      themeProvider: themeProvider,
      onAddNavPoint: (x, y) async {
        final wayPointInfo = await _addNavPoint(x, y);
        return wayPointInfo;
      },
      onWayPointSelectionChanged: _onWayPointSelectionChanged,
    );

    // 拖拽/旋转实时回调，刷新右侧信息
    game.currentSelectPointUpdate = () {
      setState(() {
        final info = game.getSelectedWayPointInfo();
        selectedWayPointInfo = info;
      });
    };
    
    // 初始化时同步加载点位
    _fetchWaypointsFromROS();
  }
  
  @override
  void dispose() {
    globalState.mode.value = Mode.normal;
    super.dispose();
  }

  // 导航点选择状态变化回调
  void _onWayPointSelectionChanged() {
    setState(() {
      final info = game.getSelectedWayPointInfo();
      selectedWayPointInfo = info;
    });
  }
  
  /// 1) 获取点位操作 (operation: "query" - 参照 MapActivity.java 中的 queryPoints)
  Future<void> _fetchWaypointsFromROS() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final points = await rosChannel.fetchMarkers();
      final navPointManager = Provider.of<NavPointManager>(context, listen: false);
      await navPointManager.setNavPoints(points);

      game.clearAllWayPoints();
      for (var p in points) {
        game.addWayPoint(p);
      }

      setState(() {
        navPoints = points;
        selectedWayPointInfo = null;
      });

      if (mounted) {
        toastification.show(
          context: context,
          type: ToastificationType.success,
          title: Text('成功获取 ${points.length} 个导航点'),
          autoCloseDuration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      print("获取点位异常: $e");
      if (mounted) {
        toastification.show(
          context: context,
          type: ToastificationType.error,
          title: Text('点位加载失败: $e'),
          autoCloseDuration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 2) 增加点位操作 (operation: "add" - 参照 CreatePointDialog.java 与 MapActivity.java 中的 savePoint)
  Future<NavPoint?> _addNavPoint(double x, double y) async {
    final navPointData = await _showAddNavPointDialog(x, y);
    if (navPointData != null) {
      setState(() {
        _isLoading = true;
      });

      final resp = await rosChannel.addWaypointService(
        name: navPointData['name'],
        type: navPointData['type'],
        x: navPointData['x'],
        y: navPointData['y'],
        yaw: navPointData['yaw'],
      );

      bool isSuccess = resp['success'] == true || resp['code'] == 0 || resp['result'] == true;

      setState(() {
        _isLoading = false;
      });

      if (mounted) {
        if (isSuccess) {
          toastification.show(
            context: context,
            type: ToastificationType.success,
            title: Text('点位 [${navPointData['name']}] 保存成功'),
            autoCloseDuration: const Duration(seconds: 2),
          );
          // 参照 MapActivity.java：保存成功后立即重新 queryPoints 刷新全量点位列表
          await _fetchWaypointsFromROS();
        } else {
          toastification.show(
            context: context,
            type: ToastificationType.error,
            title: Text('保存失败: ${resp['message'] ?? '未知错误'}'),
            autoCloseDuration: const Duration(seconds: 3),
          );
        }
      }

      return NavPoint(
        name: navPointData['name'],
        type: navPointData['type'],
        x: navPointData['x'],
        y: navPointData['y'],
        theta: navPointData['yaw'],
      );
    }
    return null;
  }

  /// 显示添加点位对话框 (参照 CreatePointDialog.java：包含 patrol/reception/charging/door 4种类型选择及方向角)
  Future<Map<String, dynamic>?> _showAddNavPointDialog(double x, double y) async {
    final TextEditingController nameController = TextEditingController();
    String selectedType = 'patrol';
    double selectedYaw = 0.0;

    final navPointManager = Provider.of<NavPointManager>(context, listen: false);
    int id = await navPointManager.getNextId();
    nameController.text = 'POINT_$id';

    final typesMap = {
      'patrol': '巡逻点',
      'reception': '接待点',
      'charging': '充电桩',
      'door': '门禁点',
    };

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.add_location_alt_rounded, color: Color(0xFF38BDF8)),
                  SizedBox(width: 8),
                  Text('创建点位', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '地图坐标: (${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})',
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '点位名称',
                        labelStyle: TextStyle(color: Color(0xFF94A3B8)),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF334155))),
                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF38BDF8))),
                      ),
                      autofocus: true,
                    ),
                    const SizedBox(height: 16),
                    const Text('点位类型:', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: typesMap.entries.map((entry) {
                        final isSelected = selectedType == entry.key;
                        return ChoiceChip(
                          label: Text(entry.value),
                          selected: isSelected,
                          selectedColor: const Color(0xFF06B6D4),
                          backgroundColor: const Color(0xFF334155),
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                          onSelected: (bool selected) {
                            if (selected) {
                              setDialogState(() {
                                selectedType = entry.key;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '朝向弧度/角度 (Yaw): ${selectedYaw.toStringAsFixed(2)} rad (${(selectedYaw * 180 / 3.14159).toStringAsFixed(0)}°)',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    Slider(
                      value: selectedYaw,
                      min: -3.14159,
                      max: 3.14159,
                      activeColor: const Color(0xFF06B6D4),
                      inactiveColor: const Color(0xFF334155),
                      onChanged: (val) {
                        setDialogState(() {
                          selectedYaw = val;
                        });
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8))),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF06B6D4),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) return;
                    Navigator.of(context).pop({
                      'name': name,
                      'type': selectedType,
                      'x': x,
                      'y': y,
                      'yaw': selectedYaw,
                    });
                  },
                  child: const Text('确认保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 3) 删除点位确认弹窗与请求 (operation: "delete" - 参照 MapActivity.java 中的 showDeletePointDialog / doDeletePoint)
  Future<void> _deleteNavPoint(NavPoint point) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFF43F5E)),
              const SizedBox(width: 8),
              Text(point.name.isNotEmpty ? point.name : '未命名点位', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            '是否要删除此点位？',
            style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消', style: TextStyle(color: Color(0xFF94A3B8))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF43F5E),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      setState(() {
        _isLoading = true;
      });

      // 发送 delete 服务 (operation: "delete")
      final resp = await rosChannel.deleteWaypointService(
        waypointId: point.name,
        name: point.name,
        type: point.type,
        x: point.x,
        y: point.y,
        yaw: point.theta,
      );

      bool isSuccess = resp['success'] == true || resp['code'] == 0 || resp['result'] == true;

      if (mounted) {
        if (isSuccess) {
          toastification.show(
            context: context,
            type: ToastificationType.success,
            title: Text('删除成功: ${point.name}'),
            autoCloseDuration: const Duration(seconds: 2),
          );
        } else {
          toastification.show(
            context: context,
            type: ToastificationType.error,
            title: Text('删除失败: ${resp['message'] ?? '未知错误'}'),
            autoCloseDuration: const Duration(seconds: 3),
          );
        }
      }

      // 参照 MapActivity.java: 删除后延迟 500ms 重新 queryPoints 全量刷新
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (mounted) {
          await _fetchWaypointsFromROS();
        }
      });
    }
  }

  /// 4) 更新点位 (operation: "update")
  Future<void> _updateNavPoint(NavPoint point) async {
    setState(() {
      _isLoading = true;
    });

    await rosChannel.updateWaypointService(
      waypointId: point.name,
      name: point.name,
      type: point.type,
      x: point.x,
      y: point.y,
      yaw: point.theta,
    );

    setState(() {
      _isLoading = false;
    });

    if (mounted) {
      toastification.show(
        context: context,
        type: ToastificationType.success,
        title: Text('点位 [${point.name}] 已成功更新'),
        autoCloseDuration: const Duration(seconds: 2),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: Stack(
        children: [
          // 游戏画布
          Listener(
            onPointerSignal: (pointerSignal) {
              if (pointerSignal is PointerScrollEvent) {
                final position = Vector2(pointerSignal.position.dx, pointerSignal.position.dy);
                game.onScroll(pointerSignal.scrollDelta.dy, position);
              }
            },
            child: GestureDetector(
              onTapDown: (details) async {
                final position = Vector2(details.localPosition.dx, details.localPosition.dy);
                await game.onTapDown(position);
              },
              onScaleStart: (details) {
                final position = Vector2(details.localFocalPoint.dx, details.localFocalPoint.dy);
                game.onScaleStart(position);
              },
              onScaleUpdate: (details) {
                final position = Vector2(details.localFocalPoint.dx, details.localFocalPoint.dy);
                game.onScaleUpdate(details.scale, position);
              },
              onScaleEnd: (details) {
                game.onScaleEnd();
              },
              child: MouseRegion(
                cursor: _getCursorForTool(selectedTool),
                child: GameWidget(game: game),
              ),
            ),
          ),
          
          // 顶部工具栏
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopToolbar(context, theme),
          ),
          
          // 左侧编辑工具栏
          Positioned(
            left: 10,
            top: 80,
            child: _buildEditToolbar(context, theme),
          ),
          
          // 右侧信息面板
          Positioned(
            right: 10,
            top: 80,
            child: _buildInfoPanel(context, theme),
          ),

          if (_isLoading)
            const Center(
              child: Card(
                color: Colors.black87,
                child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: CircularProgressIndicator(color: Color(0xFF06B6D4)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 顶部工具栏 (增加【获取点位】按钮)
  Widget _buildTopToolbar(BuildContext context, ThemeData theme) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: const Border(bottom: BorderSide(color: Color(0xFF334155))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF38BDF8), size: 20),
            onPressed: () {
              widget.onExit?.call();
              Navigator.pop(context);
            },
          ),
          const SizedBox(width: 8),
          const Text(
            '点位编辑管理面板',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 20),

          // 核心：获取点位按钮 (operation: query)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF06B6D4),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.cloud_download_rounded, size: 18),
            label: const Text('获取点位 (Query)', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: _isLoading ? null : _fetchWaypointsFromROS,
          ),

          const Spacer(),

          // 保存保存本地及同步拓扑图
          IconButton(
            icon: const Icon(Icons.save_rounded, color: Color(0xFF10B981), size: 26),
            tooltip: '保存点位并更新拓扑',
            onPressed: () async {
              List<NavPoint> navPoints = game.getAllWayPoint();
              final navPointManager = Provider.of<NavPointManager>(context, listen: false);
              await navPointManager.saveNavPoints(navPoints);
              
              final topologyMap = TopologyMap(
                points: navPoints,
                routes: [],
              );
              await rosChannel.updateTopologyMap(topologyMap);

              if (mounted) {
                toastification.show(
                  context: context,
                  type: ToastificationType.success,
                  title: const Text('保存成功！'),
                  autoCloseDuration: const Duration(seconds: 2),
                );
              }
            },
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget _buildEditToolbar(BuildContext context, ThemeData theme) {
    return Card(
      color: const Color(0xFF1E293B).withOpacity(0.9),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildEditTool(
              icon: Icons.add_location_alt_rounded,
              label: '点击地图添加',
              toolName: EditToolType.addNavPoint,
              color: const Color(0xFF38BDF8),
            ),
            const SizedBox(height: 8),
            _buildActionButton(
              icon: Icons.my_location_rounded,
              label: '获取位置添加',
              color: const Color(0xFF10B981),
              onPressed: () async {
                final robotPose = rosChannel.robotPoseMap.value;
                await _addNavPoint(robotPose.x, robotPose.y);
              },
            ),
            const SizedBox(height: 8),
            _buildEditTool(
              icon: Icons.brush_rounded,
              label: '绘制障碍物',
              toolName: EditToolType.drawObstacle,
              color: const Color(0xFFF43F5E),
            ),
            const SizedBox(height: 8),
            _buildEditTool(
              icon: Icons.auto_fix_high_rounded,
              label: '擦除障碍物',
              toolName: EditToolType.eraseObstacle,
              color: const Color(0xFF10B981),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.6), width: 1.5),
        ),
        child: Column(
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditTool({
    required IconData icon,
    required String label,
    required EditToolType toolName,
    required Color color,
  }) {
    final isActive = selectedTool == toolName;
    
    return InkWell(
      onTap: () {
        if (isActive) {
          selectedTool = null;
          game.setSelectedTool(null);
        } else {
          selectedTool = toolName;
          game.setSelectedTool(toolName);
        }
        setState(() {});
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? color.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isActive ? color : Colors.transparent, width: 1.5),
        ),
        child: Column(
          children: [
            Icon(icon, size: 24, color: isActive ? color : const Color(0xFF94A3B8)),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: isActive ? color : const Color(0xFF94A3B8),
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoPanel(BuildContext context, ThemeData theme) {
    return Card(
      color: const Color(0xFF1E293B).withOpacity(0.9),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selectedWayPointInfo != null) ...[
              _buildWayPointInfo(theme),
            ] else ...[
              const Text(
                '点位编辑说明',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 12),
              _buildInstructionItem(
                icon: Icons.add_location_alt_rounded,
                title: '增加点位',
                description: '点击【添加点位】工具，再点击地图位置，在弹窗中设置点位名称与方向。',
                color: const Color(0xFF38BDF8),
              ),
              const SizedBox(height: 10),
              _buildInstructionItem(
                icon: Icons.touch_app_rounded,
                title: '删除与选择',
                description: '点击地图点位弹出删除确认，或在选中后点击【删除点位】按钮。',
                color: const Color(0xFFF43F5E),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF06B6D4).withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.place_rounded, color: Color(0xFF38BDF8), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '目前导航点数量: ${game.wayPointCount} 个',
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildWayPointInfo(ThemeData theme) {
    final info = selectedWayPointInfo!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.location_on_rounded, color: Color(0xFF38BDF8), size: 20),
            const SizedBox(width: 6),
            const Text(
              '当前选中点位',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildInfoRow('名称', info.name),
        _buildInfoRow('类型', info.type),
        _buildInfoRow('X坐标', '${info.x.toStringAsFixed(2)} m'),
        _buildInfoRow('Y坐标', '${info.y.toStringAsFixed(2)} m'),
        _buildInfoRow('方向', '${(info.theta * 180 / 3.14159).toStringAsFixed(1)}° (${info.theta.toStringAsFixed(2)} rad)'),
        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _updateNavPoint(info),
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: const Text('更新点位'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF06B6D4),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _deleteNavPoint(info),
                icon: const Icon(Icons.delete_rounded, size: 16),
                label: const Text('删除点位'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF43F5E),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInstructionItem({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 2),
              Text(description, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  MouseCursor _getCursorForTool(EditToolType? tool) {
    switch (tool) {
      case EditToolType.addNavPoint:
        return SystemMouseCursors.precise;
      case EditToolType.drawObstacle:
      case EditToolType.eraseObstacle:
        return SystemMouseCursors.click;
      default:
        return SystemMouseCursors.basic;
    }
  }
}
