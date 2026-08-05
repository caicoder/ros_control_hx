import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

/// 在线 TTS 语音播放单例服务
class OnlinePlayer {
  static const String ttsUrl = "http://175.24.176.33:8019/tts";
  static final OnlinePlayer _instance = OnlinePlayer._internal();

  factory OnlinePlayer() => _instance;
  static OnlinePlayer get instance => _instance;

  OnlinePlayer._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final Map<String, String> _cacheMap = {};
  Directory? _cacheDir;
  bool _isInitialized = false;

  Future<void> _initCache() async {
    if (_isInitialized) return;
    try {
      final tempDir = await getTemporaryDirectory();
      _cacheDir = Directory('${tempDir.path}/tts_audio');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      _isInitialized = true;
    } catch (e) {
      print("OnlinePlayer 初始化缓存失败: $e");
    }
  }

  String _generateHash(String text) {
    return sha256.convert(utf8.encode(text)).toString();
  }

  /// 播报 TTS 语音
  Future<void> playTTS(String text, {bool useCache = true}) async {
    if (text.trim().isEmpty) return;

    print("==== OnlinePlayer 准备播报语音: '$text' ====");

    try {
      await _initCache();
      final hash = _generateHash(text);
      File? targetAudioFile;

      if (_cacheDir != null) {
        final cachedFile = File('${_cacheDir!.path}/$hash.mp3');
        if (useCache && await cachedFile.exists()) {
          targetAudioFile = cachedFile;
          print("==== OnlinePlayer 使用本地 TTS 缓存: ${cachedFile.path} ====");
        }
      }

      // 若未命中心，通过 HTTP POST 请求在线 TTS 接口下载音频
      if (targetAudioFile == null) {
        print("==== OnlinePlayer 发起 TTS 请求: $ttsUrl ====");
        final response = await http.post(
          Uri.parse(ttsUrl),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            "text": text,
            "ttsVoiceId": "",
          }),
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          if (_cacheDir != null) {
            final file = File('${_cacheDir!.path}/$hash.mp3');
            await file.writeAsBytes(response.bodyBytes);
            targetAudioFile = file;
            print("==== OnlinePlayer TTS 音频已下载并保存至: ${file.path} ====");
          }
        } else {
          print("==== OnlinePlayer TTS 请求失败: HTTP ${response.statusCode} ====");
          return;
        }
      }

      if (targetAudioFile != null && await targetAudioFile.exists()) {
        await _audioPlayer.stop();
        await _audioPlayer.play(DeviceFileSource(targetAudioFile.path));
        print("==== OnlinePlayer 正在播放音频: $text ====");
      }
    } catch (e) {
      print("==== OnlinePlayer 播报语音异常: $e ====");
    }
  }

  /// 停止/打断语音播报
  Future<void> stop() async {
    try {
      await _audioPlayer.stop();
    } catch (e) {
      print("OnlinePlayer 停止失败: $e");
    }
  }
}
