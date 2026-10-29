import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';

class UtilTools {
  static final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  static const List<String> _desktopUserAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36',
  ];

  static final Random _random = Random();

  static String? _sessionUserAgent;

  static String get default_user_agent => _sessionUserAgent ??= _desktopUserAgents[_random.nextInt(_desktopUserAgents.length)];

  /// 需要换一个 UA 时调用（例如怀疑当前 UA 被风控），下次请求生效。
  static void reset_session_user_agent() => _sessionUserAgent = null;

  /// 按 marker在 text里定位并截取一段完整的 JSON 对象。
  static String extra_json_by_marker(String text, String marker, {bool isRegex = false}) {
    // 标记匹配结束后，从哪个位置继续找 JSON 的起始 '{'
    int braceSearchFrom;

    if (isRegex) {
      final match = RegExp(marker).firstMatch(text);
      if (match == null) {
        // stderr.writeln('未找到变量定义');
        return '';
      }
      braceSearchFrom = match.end;
    } else {
      final startIdx = text.indexOf(marker);
      if (startIdx == -1) {
        // stderr.writeln('未找到变量定义');
        return '';
      }
      braceSearchFrom = startIdx + marker.length;
    }

    // 3. 从标记之后开始寻找第一个 '{'
    final braceStart = text.indexOf('{', braceSearchFrom);
    if (braceStart == -1) {
      // stderr.writeln('未找到对象起始大括号');
      return '';
    }

    int depth = 0;
    bool inString = false;
    bool escape = false;
    int braceEnd = -1;

    for (int i = braceStart; i < text.length; i++) {
      final char = text[i];

      // 处理转义符（遇到 \ 就跳过下一个字符）
      if (escape) {
        escape = false;
        continue;
      }
      if (char == '\\') {
        escape = true;
        continue;
      }

      // 处理字符串边界（只统计字符串外部的括号）
      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          depth++;
        } else if (char == '}') {
          depth--;
          if (depth == 0) {
            braceEnd = i;
            break;
          }
        }
      }
    }

    if (braceEnd == -1) return '';

    // 4. 截取完整的 JSON 片段（就是你要的那个对象）
    String json_content = text.substring(braceStart, braceEnd + 1);

    return json_content;
  }

  static int get_local_timestamp() {
    int currentTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return currentTimestamp;
  }
}
