import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'package:ym_live_stream/contract/auth_source.dart';
import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/features/favorite_store.dart';

/// 设置页的控制器。
///
/// 【为什么从 HomeController 里拆出来】
/// 这个项目原来是 GetX 一把梭：一个 HomeController 同时管主页名片、搜索、
/// 收藏、设置页登录、导入导出 —— 一个类几百行，改设置页要翻到 700 行开外，
/// 而且设置页和主页没有共同状态，硬塞在一个 controller 里纯属连坐。
///
/// 现在改用 Flutter 内建的 [ChangeNotifier]：
///   * 不依赖任何第三方状态管理库，不会因为库停更而失效；
///   * 谁监听谁清楚，`addListener` / `removeListener` 是显式的；
///   * 测试 / 预览时直接 new 一个塞假数据，不需要启动整个 app。
///
/// 【和 GetX 的对应关系】
///   `final x = 0.obs`          →  `int _x = 0; int get x => _x;`
///                                 赋值处改成调 `_setX(value)`，内部 `notifyListeners()`
///   `Obx(() => ... .value)`    →  `ListenableBuilder(listenable: controller, builder: ...)`
///
/// 【注意：这里只管设置页自己的状态】
/// 关注的增删（FavoriteStore）是全局数据，不归这里；
/// 设置页只是「读取一份快照用于导入导出」，读的是 FavoriteStore.instance。
class SettingsController extends ChangeNotifier {
  // ===================== 分类选中 =====================

  /// 设置页当前选中的分类（0 常规 / 1 哔哩哔哩 / 2 斗鱼 / 3 抖音）
  int _section = 0;
  int get section => _section;

  set section(int value) {
    if (value == _section) return;
    _section = value;
    notifyListeners();
  }

  // ===================== 导入 / 导出 =====================

  /// 关注列表导入导出是否正在执行（防连点 + 按钮转圈）
  bool _isExporting = false;
  bool get isExporting => _isExporting;

  bool _isImporting = false;
  bool get isImporting => _isImporting;

  /// 导入 + 导出共用同一把「忙碌」闸门：两个按钮要互相禁用
  bool get isFileBusy => _isExporting || _isImporting;

  // ===================== 哔哩哔哩登录 =====================

  /// B 站登录进行中（二维码弹窗展示期间为 true）
  bool _isLoggingIn = false;
  bool get isLoggingIn => _isLoggingIn;

  set isLoggingIn(bool value) {
    if (value == _isLoggingIn) return;
    _isLoggingIn = value;
    notifyListeners();
  }

  /// B 站登录态摘要：已登录时显示昵称或用户 id，未登录显示空串
  String _loginLabel = '';
  String get loginLabel => _loginLabel;

  bool get isLoggedIn => _loginLabel.isNotEmpty;

  // ===================== 生命周期 =====================

  /// 页面初始化时拉一次登录态。
  ///
  /// 【为什么不写在构造函数里】构造函数要能纯同步、可预测，
  /// 预览 / 测试 new 一个 controller 时不应该顺手发网络请求。
  /// 由页面在自己的 initState 里显式调用。
  void init() {
    unawaited(loadBilibiliLoginStateOnStartup());
  }

  /// 从后端读一下登录态摘要。
  ///
  /// 【必须区分「有 Cookie」和「Cookie 还有效」】
  /// 只判断本地有没有凭证是不够的：凭证可能已经过期，
  /// 那种情况下界面还显示「已登录」，用户会以为登录态还在。
  /// currentAccount() 会真的去平台校验一次，失效就返回 null。
  Future<void> refreshBilibiliLoginState() async {
    final auth = AuthSourceRegistry.find(LIVE_SITE_E.LIVE_SITE_BILIBILI);

    // 没注册登录实现（开源版没接后端）：静默显示未登录，不报错
    if (auth == null) {
      _setLoginLabel('');
      return;
    }

    try {
      final account = await auth.currentAccount();
      if (account == null) {
        _setLoginLabel('');
        return;
      }

      final uid = account.userId ?? '';
      final nickname = account.nickname ?? '';
      // 优先显示昵称，其次 UID，都没有就只显示「已登录」
      if (nickname.isNotEmpty) {
        _setLoginLabel('已登录 ($nickname)');
      } else if (uid.isNotEmpty) {
        _setLoginLabel('已登录 (UID $uid)');
      } else {
        _setLoginLabel('已登录');
      }
    } catch (_) {
      _setLoginLabel('');
    }
  }

  void _setLoginLabel(String value) {
    if (value == _loginLabel) return;
    _loginLabel = value;
    notifyListeners();
  }

  /// 启动时加载 B 站登录态。
  ///
  /// 【之前漏掉了这一步】refreshBilibiliLoginState 只在「点完登录」后调用过，
  /// 应用重启后没人读配置，label 一直是空串 ——
  /// 表现就是「登录好了，重开应用又显示未登录」。
  Future<void> loadBilibiliLoginStateOnStartup() async {
    await refreshBilibiliLoginState();
  }

  // ===================== 导入关注列表 =====================

  /// 导入关注列表：选择 JSON 文件 → 合并进本地存储。
  ///
  /// 返回值只用于给调用方决定提示文案，UI 提示在页面层做。
  Future<({bool ok, String message})> importFollows() async {
    if (_isImporting) return (ok: false, message: '正在导入中');
    _isImporting = true;
    notifyListeners();
    try {
      // file_picker 12+ 的 API：pickFile 是静态方法，直接返回单个 PlatformFile
      // （老版本的 FilePicker.platform.pickFiles(...).files.first 写法已不可用）
      final picked = await FilePicker.pickFile(
        dialogTitle: '选择关注列表文件',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      // 用户取消选择
      if (picked == null) {
        return (ok: false, message: '');
      }

      // 桌面端的 PlatformFile 通常带着真实路径，优先按路径读；
      // 拿不到路径时退回插件的 readAsBytes()，细节见 _readPickedFile。
      final text = await _readPickedFile(picked);
      if (text == null) {
        return (ok: false, message: '无法读取文件内容');
      }

      final result = await FavoriteStore.instance.importFromJson(text);

      final parts = <String>[];
      if (result.added > 0) parts.add('新增 ${result.added}');
      if (result.updated > 0) parts.add('更新 ${result.updated}');
      if (result.skipped > 0) parts.add('跳过 ${result.skipped}');
      return (ok: true, message: parts.isEmpty ? '没有可导入的数据' : '导入完成：${parts.join('，')}');
    } on FormatException catch (e) {
      return (ok: false, message: '文件格式不正确：${e.message}');
    } catch (e) {
      return (ok: false, message: '导入失败：$e');
    } finally {
      _isImporting = false;
      notifyListeners();
    }
  }

  /// 把选中的文件读成字符串：优先用真实路径，其次用平台读取接口。
  ///
  /// 【别用 file.bytes】file_picker 12+ 把 PlatformFile 改成了抽象接口，
  /// `bytes` 字段已经不存在（那是老版本 FilePickerResult 时代的写法）。
  /// 新版提供的是 `readAsBytes()` / `readAsByteStream()`，
  /// 而且 path 在云端/内容提供者场景下可能是 null，所以两条路都要留。
  Future<String?> _readPickedFile(PlatformFile file) async {
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      final f = File(path);
      if (await f.exists()) {
        return f.readAsString();
      }
    }

    // path 拿不到（或本地文件已不存在）时退回插件自己的读取接口
    try {
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  // ===================== 导出关注列表 =====================

  /// 导出关注列表：选择保存位置 → 写入 JSON 文件。
  Future<({bool ok, String message})> exportFollows() async {
    if (_isExporting) return (ok: false, message: '正在导出中');
    _isExporting = true;
    notifyListeners();
    try {
      final rooms = FavoriteStore.instance.all();
      if (rooms.isEmpty) {
        return (ok: false, message: '还没有关注任何直播间');
      }

      final json = FavoriteStore.instance.exportToJson();

      // file_picker 12+ 的 saveFile：bytes 是**必填**参数（插件自己负责落盘），
      // 返回值也从 String? 变成了 Uri?。
      final saved = await FilePicker.saveFile(
        dialogTitle: '导出关注列表',
        fileName: 'ym_live_stream_follows.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: utf8.encode(json),
      );
      if (saved == null) {
        return (ok: false, message: ''); // 用户取消
      }

      // 有的平台返回 file:// 形式的 URI，有的直接给绝对路径，统一转成可读路径
      final path = saved.scheme == 'file' ? saved.toFilePath() : saved.toString();

      return (ok: true, message: '已导出 ${rooms.length} 条关注到 $path');
    } catch (e) {
      return (ok: false, message: '导出失败：$e');
    } finally {
      _isExporting = false;
      notifyListeners();
    }
  }
}
