import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';
// Hive.initFlutter() 定义在这个包里（hive 包本身没有它），移动端分支要用。
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ym_live_stream/core/app_paths.dart';
import 'package:ym_live_stream/contract/live_models.dart';

/// 一条收藏（关注）记录。
///
/// 只保存「进入直播间所必需」的字段：
///   room_id / fake_room_id / 房间标题 / 主播名 / 头像 / 平台 / 是否特别关注
///
/// 故意不保存 show_status（开播状态是易变的，每次加载/刷新现查），
/// 也不保存 http_header（含 cookie）和 video_set（带签名的临时流地址）。
class FavoriteRoom {
  /// 房间标识。数字或字母 id 都可能（快手是字母短 id）。
  final String roomId;

  /// 各平台自己用的辅助房间号：
  /// 斗鱼 = 房间号本身；抖音 = 内部数字 id；B站 = 短号（可能为 null）
  final String? fakeRoomId;

  final String roomName;
  final String ownerName;
  final String ownerProfileUrl;
  final LIVE_SITE_E site;

  /// 是否「特别关注」。
  ///
  /// 关注 = 进了关注列表；特别关注 = 还会额外出现在主页的名片区。
  /// 只有 true 的才上主页，普通关注只在「我的关注」页里能看到。
  final bool specialFollowed;

  const FavoriteRoom({
    required this.roomId,
    required this.ownerName,
    required this.roomName,
    required this.ownerProfileUrl,
    required this.site,
    this.fakeRoomId,
    this.specialFollowed = false,
  });

  /// 用 room_id 作为键值（各平台存下来的 room_id 都能直接拿去请求）
  String get key => '${site.name}_$roomId';

  /// 复制一份并改指定字段（特别关注开关直接用它，避免到处拼构造参数）
  FavoriteRoom copyWith({bool? specialFollowed}) => FavoriteRoom(
        roomId: roomId,
        fakeRoomId: fakeRoomId,
        roomName: roomName,
        ownerName: ownerName,
        ownerProfileUrl: ownerProfileUrl,
        site: site,
        specialFollowed: specialFollowed ?? this.specialFollowed,
      );

  /// 用最新查到的元信息更新房名/主播名/头像。
  ///
  /// 传空串表示这项没取到，**保留原值**，不会把已有信息清空。
  /// 返回 null 表示三项都没变化 —— 调用方据此跳过写入，避免无谓落盘。
  FavoriteRoom? copyWithMeta({String? roomName, String? ownerName, String? ownerProfileUrl}) {
    final nextRoomName = (roomName != null && roomName.isNotEmpty) ? roomName : this.roomName;
    final nextOwnerName = (ownerName != null && ownerName.isNotEmpty) ? ownerName : this.ownerName;
    final nextProfile = (ownerProfileUrl != null && ownerProfileUrl.isNotEmpty) ? ownerProfileUrl : this.ownerProfileUrl;

    // 全都没变就没有写盘的必要
    if (nextRoomName == this.roomName && nextOwnerName == this.ownerName && nextProfile == this.ownerProfileUrl) {
      return null;
    }

    return FavoriteRoom(
      roomId: roomId,
      fakeRoomId: fakeRoomId,
      roomName: nextRoomName,
      ownerName: nextOwnerName,
      ownerProfileUrl: nextProfile,
      site: site,
      specialFollowed: specialFollowed,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'room_id': roomId,
        'fake_room_id': fakeRoomId,
        'room_name': roomName,
        'owner_name': ownerName,
        'owner_profile_url': ownerProfileUrl,
        'live_site': site.name,
        'special_followed': specialFollowed,
      };

  static FavoriteRoom? fromMap(Object? raw) {
    if (raw is! Map) return null;

    // 【兼容老数据】room_id 以前存的是 int，现在统一当字符串处理。
    // 老版本写进去的 6925114 读出来会变成 "6925114"，行为不变。
    final rawId = raw['room_id'];
    final roomId = rawId?.toString().trim();
    if (roomId == null || roomId.isEmpty) return null; // 没有房间号就是脏数据，直接丢

    final siteName = raw['live_site'];
    final site = LIVE_SITE_E.values.firstWhere(
      (e) => e.name == siteName,
      orElse: () => LIVE_SITE_E.LIVE_SITE_DOUYU,
    );

    final rawFake = raw['fake_room_id']?.toString().trim();

    return FavoriteRoom(
      roomId: roomId,
      fakeRoomId: (rawFake != null && rawFake.isNotEmpty) ? rawFake : null,
      roomName: (raw['room_name'] as String?) ?? '',
      ownerName: (raw['owner_name'] as String?) ?? '',
      ownerProfileUrl: (raw['owner_profile_url'] as String?) ?? '',
      site: site,
      // 老数据里没有这个键，缺省 false —— 加这个字段之前存下的关注都算普通关注
      specialFollowed: raw['special_followed'] == true,
    );
  }
}

/// 收藏列表的本地存储。
///
/// 用 Hive 的二进制 box（不是明文 json 文件）。
///
/// 【目录选择】桌面端用 [AppPaths.dataDirectory]（系统标准的应用数据目录），
/// 移动端继续用 `Hive.initFlutter()` 的默认位置 —— 手机上的默认位置本来就是
/// 应用沙盒私有目录，不存在桌面端那种「数据落到用户文档夹」的问题。
///
/// 【磁盘不可用时降级为内存模式】某些环境（权限异常、只读文件系统）下
/// 创建 box 会失败。这里先探测目录可写性，探测不过就完全不碰磁盘、
/// 改用内存 Map 顶上 —— 收藏功能照常可用（只是重启后丢失），
/// 而不是让整个应用启动失败。
class FavoriteStore {
  static const String boxName = 'ym_favorites';

  /// 全局单例：main() 里 init 过一次，页面里直接用同一份 box。
  /// （不用 Get.find，避免“main 里初始化了一个实例、绑定里又 put 一个新实例”导致 box 为空）
  static final FavoriteStore instance = FavoriteStore._();

  FavoriteStore._();

  Box<dynamic>? _box;

  /// 磁盘不可用时的兜底存储（键值结构与 box 一致）
  final Map<dynamic, dynamic> _memory = {};

  /// 是否正在使用内存兜底
  bool get isMemoryMode => _box == null;

  /// 在 main() 里 await 一次即可，之后同步读写。
  ///
  /// 任何一步失败都只降级、不抛异常 —— 收藏是附属功能，
  /// 不能因为它让应用直接起不来（真机上会表现为“黑屏打不开”）。
  Future<void> init() async {
    if (_box != null) return;

    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // 桌面端：用系统标准的应用数据目录
        // （Windows: %APPDATA%，Linux: ~/.local/share，macOS: ~/Library/Application Support）
        final dir = await AppPaths.dataDirectory();
        await _ensureWritable(dir);

        Hive.init(dir.path);
      } else {
        // 移动端：Hive 默认目录就是应用沙盒私有位置，保持原样
        await Hive.initFlutter();
      }

      _box = await Hive.openBox<dynamic>(boxName);
    } catch (e) {
      // 【关键】不要 rethrow：Hive 的失败还可能异步逃逸到 zone 之外，
      // 但这里先把它挡在同步路径上，应用继续以内存模式运行。
      debugPrint('[FavoriteStore] 磁盘不可用，收藏改为内存模式（重启后丢失）: $e');
      _box = null;
    }
  }

  /// 探测目录是否真的可写。
  ///
  /// 必须在 `Hive.init()` 之前做：目录不可写时，Hive 打开 box 的过程中
  /// 会调用内部的清理逻辑再失败，异常可能在别处异步冒出，来不及捕获。
  Future<void> _ensureWritable(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final probe = File('${dir.path}${Platform.pathSeparator}.write_probe');
    await probe.writeAsString('ok');
    await probe.delete();
  }

  /// 统一读取：box 和内存兜底走同一套接口
  dynamic _read(dynamic key) => _box?.get(key) ?? _memory[key];

  /// 统一写入
  Future<void> _write(dynamic key, dynamic value) async {
    final box = _box;
    if (box != null) {
      await box.put(key, value);
    } else {
      _memory[key] = value;
    }
  }

  /// 统一删除
  Future<void> _delete(dynamic key) async {
    final box = _box;
    if (box != null) {
      await box.delete(key);
    } else {
      _memory.remove(key);
    }
  }

  /// 所有键
  Iterable<dynamic> get _keys => _box?.keys ?? _memory.keys;

  /// 是否包含某个键
  bool _hasKey(dynamic key) => _box?.containsKey(key) ?? _memory.containsKey(key);

  /// 全部收藏（按写入顺序）
  List<FavoriteRoom> all() {
    final result = <FavoriteRoom>[];
    for (final key in _keys) {
      final room = FavoriteRoom.fromMap(_read(key));
      if (room != null) result.add(room);
    }
    return result;
  }

  /// 只要「特别关注」的那些（主页名片区用）
  List<FavoriteRoom> specialFollowed() => all().where((r) => r.specialFollowed).toList();

  /// 取单条记录，没有则返回 null
  FavoriteRoom? get(LIVE_SITE_E site, String roomId) {
    if (roomId.trim().isEmpty) return null;
    return FavoriteRoom.fromMap(_read('${site.name}_${roomId.trim()}'));
  }

  bool contains(LIVE_SITE_E site, String roomId) {
    if (roomId.trim().isEmpty) return false;
    return _hasKey('${site.name}_${roomId.trim()}');
  }

  /// 是否特别关注。未关注 / 无记录一律 false
  bool isSpecialFollowed(LIVE_SITE_E site, String roomId) => get(site, roomId)?.specialFollowed ?? false;

  Future<void> add(FavoriteRoom room) async {
    await _write(room.key, room.toMap());
  }

  /// 设置某条记录是否特别关注。
  ///
  /// 记录不存在时直接忽略：特别关注是「关注」之上的附加状态，
  /// 不能凭空创建一份没有主播信息的记录出来。
  Future<void> setSpecialFollowed(LIVE_SITE_E site, String roomId, bool value) async {
    final existing = get(site, roomId);
    if (existing == null) return;
    if (existing.specialFollowed == value) return;
    await add(existing.copyWith(specialFollowed: value));
  }

  Future<void> remove(LIVE_SITE_E site, String roomId) async {
    await _delete('${site.name}_${roomId.trim()}');
  }

  // ===== 关注列表的导入 / 导出 =====
  //
  // 导出格式是一个纯 JSON 数组，每项就是 FavoriteRoom.toMap() 的内容。
  // 因为 toMap 用的就是 room_id / owner_name 这些下划线字段名，
  // 导出文件和内部存储结构天然一致，导入时直接 fromMap 就能还原。
  //
  // 注意：导出的是**明文 JSON**（用户要拿去备份/迁移，必须可读）。
  // 这与「本地存储不用明文」不冲突 —— 那个要求针对的是运行时存储，
  // 而导出的文件是用户显式选择位置后生成的外部产物。

  /// 导出全部关注为 JSON 文本
  String exportToJson() {
    final rooms = all().map((r) => r.toMap()).toList();
    return const JsonEncoder.withIndent('  ').convert(rooms);
  }

  /// 从 JSON 文本导入关注，返回 (新增数, 覆盖数, 跳过数)。
  ///
  /// 合并策略：按 key（平台+房间号）判断，已存在的用导入数据覆盖 ——
  /// 这样用户在一台机器上改了「特别关注」，同步过去也能生效。
  /// 单条解析失败只跳过它，不会让整次导入失败。
  Future<({int added, int updated, int skipped})> importFromJson(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! List) {
      throw const FormatException('导入文件的根节点必须是 JSON 数组');
    }

    var added = 0;
    var updated = 0;
    var skipped = 0;

    for (final raw in decoded) {
      final room = FavoriteRoom.fromMap(raw);
      if (room == null) {
        skipped++; // 缺房间号 / 结构不对，跳过这一条
        continue;
      }

      final exists = _hasKey(room.key);
      await _write(room.key, room.toMap());
      if (exists) {
        updated++;
      } else {
        added++;
      }
    }

    return (added: added, updated: updated, skipped: skipped);
  }
}
