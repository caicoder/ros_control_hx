import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

class PlayRequest {
  final String text;
  final bool useCache;

  PlayRequest(this.text, this.useCache);
}

/// 在线 TTS 语音播放单例服务 (移植自 Java 代码逻辑)
class OnlinePlayer {
  static const String ttsUrl = "http://175.24.176.33:8019/tts";
  static final OnlinePlayer _instance = OnlinePlayer._internal();

  factory OnlinePlayer() => _instance;
  static OnlinePlayer get instance => _instance;

  final AudioPlayer _audioPlayer = AudioPlayer();
  final Map<String, String> _audioFileMap = {};
  Directory? _audioCacheDir;
  bool _isInitialized = false;

  final Queue<PlayRequest> _playQueue = Queue<PlayRequest>();
  bool _isProcessingRequest = false;

  OnlinePlayer._internal() {
    _initAudioCache();
    
    // 监听播放完成事件，自动处理队列中下一个
    _audioPlayer.onPlayerComplete.listen((event) {
      _cleanupResources();
      _processNextRequest();
    });
  }

  Future<void> _initAudioCache() async {
    if (_isInitialized) return;
    try {
      final tempDir = await getTemporaryDirectory();
      _audioCacheDir = Directory('${tempDir.path}/tts_audio');
      if (!await _audioCacheDir!.exists()) {
        await _audioCacheDir!.create(recursive: true);
      }
      _isInitialized = true;
    } catch (e) {
      print("OnlinePlayer 初始化缓存失败: $e");
    }
  }

  String _generateHash(String text) {
    return sha256.convert(utf8.encode(text)).toString();
  }

  /// 判断指定文本的 TTS 音频是否已被缓存且本地文件存在
  Future<bool> isAudioCached(String text) async {
    if (text.trim().isEmpty) return false;
    await _initAudioCache();
    final hash = _generateHash(text);
    if (_audioCacheDir != null) {
      final cachedFile = File('${_audioCacheDir!.path}/$hash.mp3');
      if (await cachedFile.exists()) {
        return true;
      }
    }
    return false;
  }

  /// 提前下载音频到缓存（只预下载，不播放）
  Future<void> preloadAudioCache(String text) async {
    if (text.trim().isEmpty) return;
    if (await isAudioCached(text)) {
      print("TTS 音频已存在缓存，跳过重复下载: $text");
      return;
    }

    print("开始提前下载 TTS 音频缓存(不播放) --- 文本内容：$text");
    await _initAudioCache();
    final hash = _generateHash(text);

    try {
      final response = await http.post(
        Uri.parse(ttsUrl),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({
          "text": text,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        if (_audioCacheDir != null) {
          final file = File('${_audioCacheDir!.path}/$hash.mp3');
          await file.writeAsBytes(response.bodyBytes);
          print("TTS 音频提前下载并缓存完成 --- 文本内容：$text | 文件路径：${file.path}");
        }
      } else {
        print("提前下载缓存失败: HTTP ${response.statusCode}");
      }
    } catch (e) {
      print("提前下载缓存网络请求失败: $e");
    }
  }

  /// 批量提前下载 List 中的文案音频到缓存
  Future<void> preloadAudioCacheList(List<String> textList) async {
    if (textList.isEmpty) return;
    for (String text in textList) {
      await preloadAudioCache(text);
    }
  }

  /// 加载常用的语音句子并预下载音频缓存
  Future<void> preloadCommonAudioSentences() async {
    List<String> commonSentences = [
      "请讲~",
      "小悉，还没有连接上网络，请帮我检查联网哦"
    ];
    print("开始加载并预下载常用的语音句子...");
    await preloadAudioCacheList(commonSentences);
  }

  /// 判断是否正在播放
  bool isSpeaking() {
    return _audioPlayer.state == PlayerState.playing;
  }

  /// 暂停播放
  Future<void> pause() async {
    if (_audioPlayer.state == PlayerState.playing) {
      await _audioPlayer.pause();
    }
  }

  /// 恢复播放
  Future<void> resume() async {
    if (_audioPlayer.state == PlayerState.paused) {
      await _audioPlayer.resume();
    }
  }

  /// 等待执行的播放方法（加入队列）
  void playTTSWait(String text, {bool useCache = true}) {
    if (text.trim().isEmpty) return;
    _playQueue.add(PlayRequest(text, useCache));
    if (!_isProcessingRequest) {
      _processNextRequest();
    }
  }

  /// 立即播报 TTS 语音（会打断当前播报并清空队列）
  Future<void> playTTS(String text, {bool useCache = true}) async {
    if (text.trim().isEmpty) return;
    print("playTTS 方法入参 --- 文本内容：$text | 是否使用缓存：$useCache");

    await interruptCurrentSpeech();

    _isProcessingRequest = true;
    await _executePlayRequest(text, useCache);
  }

  Future<void> _processNextRequest() async {
    if (_playQueue.isNotEmpty) {
      _isProcessingRequest = true;
      final request = _playQueue.removeFirst();
      await _executePlayRequest(request.text, request.useCache);
    } else {
      _isProcessingRequest = false;
    }
  }

  Future<void> _executePlayRequest(String text, bool useCache) async {
    try {
      await _initAudioCache();
      final hash = _generateHash(text);
      File? targetAudioFile;

      if (_audioCacheDir != null) {
        final cachedFile = File('${_audioCacheDir!.path}/$hash.mp3');
        if (useCache && await cachedFile.exists()) {
          targetAudioFile = cachedFile;
          // print("==== OnlinePlayer 使用本地 TTS 缓存: ${cachedFile.path} ====");
        }
      }

      if (targetAudioFile == null) {
        // HTTP 请求体 JSON 入参
        final requestBodyJson = jsonEncode({
          "text": text,
        });
        print("HTTP 请求体 JSON 入参 --- $requestBodyJson");
        print("HTTP 请求信息 --- URL：$ttsUrl | 请求方式：POST");

        final response = await http.post(
          Uri.parse(ttsUrl),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: requestBodyJson,
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          if (_audioCacheDir != null) {
            final file = File('${_audioCacheDir!.path}/$hash.mp3');
            await file.writeAsBytes(response.bodyBytes);
            targetAudioFile = file;
          }
        } else {
          print("网络请求失败: 服务器错误 ${response.statusCode}, Body: ${response.body}");
          _processNextRequest();
          return;
        }
      }

      if (targetAudioFile != null && await targetAudioFile.exists()) {
        await _audioPlayer.stop();
        print("开始音频播放${targetAudioFile.path}");
        await _audioPlayer.play(DeviceFileSource(targetAudioFile.path));
      } else {
        _processNextRequest();
      }
    } catch (e) {
      print("播放失败 初始化失败: $e");
      _processNextRequest();
    }
  }

  void _cleanupResources() {
    // 可以在此处做临时文件的清理逻辑等
  }

  /// 打断当前对话/TTS播放：
  /// 1. 清空播放队列
  /// 2. 停止并释放播放器
  Future<void> interruptCurrentSpeech() async {
    print("打断当前对话");
    _playQueue.clear();
    
    if (_audioPlayer.state == PlayerState.playing) {
      print("播放停止");
      await _audioPlayer.stop();
    }
    
    _cleanupResources();
    _isProcessingRequest = false;
  }

  /// 打断当前对话 (别名方法)
  Future<void> interruptConversation() async {
    await interruptCurrentSpeech();
  }

  /// 清除所有缓存
  Future<void> clearAudioCache() async {
    await interruptCurrentSpeech();
    if (_audioCacheDir != null && await _audioCacheDir!.exists()) {
      final files = _audioCacheDir!.listSync();
      for (var file in files) {
        if (file is File) {
          await file.delete();
        }
      }
    }
  }

  Future<void> stop() async {
    await interruptCurrentSpeech();
  }
}
