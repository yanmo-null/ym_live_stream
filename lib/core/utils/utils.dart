import 'dart:io';
import 'dart:math';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
// import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class UtilTools {
  static final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  // ===================== 统一的 User-Agent =====================

  /// 候选 UA 池：都是真实存在过的桌面端 Chrome 版本。
  /// 注意不要填超过当前真实发布版本的号（例如 Chrome/150、Edg/151），
  /// 不存在的版本号比"没有延时"更容易被判定为爬虫。
  static const List<String> _desktopUserAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36',
  ];

  static final Random _random = Random();

  /// 会话级 UA：整个进程生命周期内保持不变。
  /// 这样既避免了"所有客户端共用同一个 UA 字符串"，
  /// 又保证同一房间的一次进房流程（页面 HTML -> getEncryption -> getH5PlayV1）
  /// 内部 UA 一致——三个请求 UA 各不相同反而是更强的异常特征。
  static String? _sessionUserAgent;

  static String get default_user_agent =>
      _sessionUserAgent ??= _desktopUserAgents[_random.nextInt(_desktopUserAgents.length)];

  /// 需要换一个 UA 时调用（例如怀疑当前 UA 被风控），下次请求生效。
  static void reset_session_user_agent() => _sessionUserAgent = null;
  // static Future<bool> check_fileWR_permission() async {
  //   try {
  //     if (!Platform.isAndroid) {
  //       return true;
  //     }
  //     Permission permission = Permission.storage;
  //     var androidIndo = await deviceInfo.androidInfo;
  //     if (androidIndo.version.sdkInt >= 33) {
  //       permission = Permission.manageExternalStorage;
  //     }

  //     var status = await permission.status;
  //     if (status == PermissionStatus.granted) {
  //       return true;
  //     }
  //     status = await permission.request();
  //     if (status.isGranted) {
  //       return true;
  //     } else {
  //       SmartDialog.showToast("请授予文件访问权限");
  //       return false;
  //     }
  //   } catch (e) {
  //     return false;
  //   }
  // }

  /// 按 [marker] 在 [text] 里定位并截取一段完整的 JSON 对象。
  ///
  /// [isRegex] 为 false（默认）时 [marker] 按纯字符串字面量匹配，行为与以前完全一致；
  /// 为 true 时 [marker] 按正则匹配，用于标记里含有「易变片段」的场景
  /// （例如抖音 RSC 数据里的 `$L11` 编号会随前端构建变成 `$L12` / `$L8`）。
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
