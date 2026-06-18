import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ros_flutter_gui_app/provider/ros_channel.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/them_provider.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/language/l10n/gen/app_localizations.dart';
import 'package:ros_flutter_gui_app/utils/motivational_quotes.dart';

class ConnectPage extends StatefulWidget {
  @override
  _ConnectPageState createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> with SingleTickerProviderStateMixin {
  final TextEditingController _ipController =
      TextEditingController(text: '127.0.0.1');
  final int fixedPort = 9090;
  bool _isConnecting = false;
  late AnimationController _bgAnimationController;
  late Animation<Color?> _colorAnimation1;
  late Animation<Color?> _colorAnimation2;
  late String _currentQuote;

  @override
  void initState() {
    super.initState();
    _currentQuote = motivationalQuotes[Random().nextInt(motivationalQuotes.length)];
    
    _bgAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final primary = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    
    _colorAnimation1 = ColorTween(
      begin: primary.withOpacity(0.05),
      end: primary.withOpacity(0.3),
    ).animate(_bgAnimationController);
    
    _colorAnimation2 = ColorTween(
      begin: primary.withOpacity(0.2),
      end: surface.withOpacity(0.05),
    ).animate(_bgAnimationController);
  }

  @override
  void dispose() {
    _bgAnimationController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<bool>(
        future: initGlobalSetting(),
        builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('发生错误：${snapshot.error}'));
          }

          _ipController.text = globalSetting.robotIp;

          return AnimatedBuilder(
            animation: _bgAnimationController,
            builder: (context, child) {
              return Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _colorAnimation1.value ?? Theme.of(context).colorScheme.primary.withOpacity(0.05),
                      _colorAnimation2.value ?? Theme.of(context).colorScheme.primary.withOpacity(0.1),
                    ],
                  ),
                ),
                child: child,
              );
            },
            child: SafeArea(
              child: Stack(
                children: [
                  // 居中小窗口
                  Center(
                    child: Container(
                      constraints: const BoxConstraints(
                        maxWidth: 420,
                        maxHeight: 550,
                      ),
                      margin: const EdgeInsets.all(24.0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                            blurRadius: 30,
                            offset: const Offset(0, 15),
                          ),
                        ],
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                          width: 2.0,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "骅羲智能", // User requested text
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Brush Script MT',
                                fontStyle: FontStyle.italic,
                                letterSpacing: 2.0,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            // 随机激励语
                            Text(
                              _currentQuote,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                fontStyle: FontStyle.italic,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 32),

                            // IP地址输入框 (端口号输入框已被隐藏)
                            TextField(
                              controller: _ipController,
                              decoration: InputDecoration(
                                labelText: AppLocalizations.of(context)!.ip_address,
                                hintText: "请输入 3588的ip 地址",
                                labelStyle: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                prefixIcon: Icon(
                                  Icons.computer,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: Theme.of(context).colorScheme.primary,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),

                            // 连接按钮
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _isConnecting ? null : _handleConnect,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  backgroundColor: Theme.of(context).colorScheme.primary,
                                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                  elevation: 2,
                                ),
                                child: _isConnecting
                                    ? SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Theme.of(context).colorScheme.onPrimary,
                                        ),
                                      )
                                    : Text(
                                        AppLocalizations.of(context)!.connect_robot,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 24),

                            // 主题切换
                            // Container(
                            //   decoration: BoxDecoration(
                            //     color: Theme.of(context).colorScheme.surface.withOpacity(0.1),
                            //     borderRadius: BorderRadius.circular(12),
                            //     border: Border.all(
                            //       color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                            //     ),
                            //   ),
                            //   child: Padding(
                            //     padding: const EdgeInsets.all(8.0),
                            //     child: Row(
                            //       mainAxisAlignment: MainAxisAlignment.center,
                            //       children: [
                            //         Icon(
                            //           Icons.palette_outlined,
                            //           size: 18,
                            //           color: Theme.of(context).colorScheme.primary,
                            //         ),
                            //         const SizedBox(width: 8),
                            //         Expanded(
                            //           child: SegmentedButton<ThemeMode>(
                            //             segments: [
                            //               ButtonSegment(
                            //                 value: ThemeMode.system,
                            //                 icon: Icon(Icons.brightness_auto, size: 18),
                            //                 label: Text(
                            //                   AppLocalizations.of(context)!.auto,
                            //                   style: const TextStyle(fontSize: 12),
                            //                 ),
                            //               ),
                            //               ButtonSegment(
                            //                 value: ThemeMode.light,
                            //                 icon: Icon(Icons.light_mode, size: 18),
                            //                 label: Text(
                            //                   AppLocalizations.of(context)!.light,
                            //                   style: const TextStyle(fontSize: 12),
                            //                 ),
                            //               ),
                            //               ButtonSegment(
                            //                 value: ThemeMode.dark,
                            //                 icon: Icon(Icons.dark_mode, size: 18),
                            //                 label: Text(
                            //                   AppLocalizations.of(context)!.dark,
                            //                   style: const TextStyle(fontSize: 12),
                            //                 ),
                            //               ),
                            //             ],
                            //             selected: {
                            //               Provider.of<ThemeProvider>(context).themeMode
                            //             },
                            //             onSelectionChanged: (Set<ThemeMode> selection) {
                            //               Provider.of<ThemeProvider>(context, listen: false)
                            //                   .updateThemeMode(selection.first.index);
                            //             },
                            //             style: ButtonStyle(
                            //               side: MaterialStateProperty.all(BorderSide(
                            //                 color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                            //               )),
                            //             ),
                            //           ),
                            //         ),
                            //       ],
                            //     ),
                            //   ),
                            // ),
                          ],
                        ),
                      ),
                    ),
                  ),

                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleConnect() async {
    setState(() => _isConnecting = true);
    try {
      final String ip = _ipController.text;
      final int port = fixedPort;

      final provider = Provider.of<RosChannel>(context, listen: false);
      globalSetting.setRobotIp(ip);
      globalSetting.setRobotPort(fixedPort.toString());

      final error = await provider.connect("ws://$ip:$port");
      if (error.isEmpty) {
        Navigator.pushNamed(context, "/map");
      } else {
        toastification.show(
          context: context,
          title: Text("connect to ROS failed: $error"),
          autoCloseDuration: const Duration(seconds: 5),
        );
      }
    } finally {
      setState(() => _isConnecting = false);
    }
  }
}
