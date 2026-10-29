import 'dart:convert';

import 'package:hive/hive.dart';

import 'package:ym_live_stream/contract/live_models.dart';

/// 一条收藏（关注）记录。
class FavoriteRoom {
  final int roomId;

  /// 各平台自己用的辅助房间号：
  /// 斗鱼 = 房间号本身；抖音 = 内部数字 id；B站 = 短号（可能为 0）
  final int? fakeRoomId;

  final String roomName;
  final String ownerName;
  final String ownerProfileUrl;
  final LIVE_SITE_E site;

  /// 是否「特别关注」。
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

  /// 用 room_id 作为键值（斗鱼 / 抖音 / B站 存下来的 room_id 都能直接拿去请求）
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

    final roomId = raw['room_id'];
    if (roomId is! int || roomId <= 0) return null; // 没有房间号就是脏数据，直接丢

    final siteName = raw['live_site'];
    final site = LIVE_SITE_E.values.firstWhere((e) => e.name == siteName, orElse: () => LIVE_SITE_E.LIVE_SITE_DOUYU);

    return FavoriteRoom(
      roomId: roomId,
      fakeRoomId: raw['fake_room_id'] is int ? raw['fake_room_id'] as int : null,
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
/// 用 Hive 的二进制 box（不是明文 json 文件），
/// 目录由 Hive.initFlutter() 交给 path_provider 决定，不随工作目录漂移。
class FavoriteStore {
  static const String boxName = 'ym_favorites';

  /// 全局单例：main() 里 init 过一次，页面里直接用同一份 box。
  /// （不用 Get.find，避免“main 里初始化了一个实例、绑定里又 put 一个新实例”导致 box 为空）
  static final FavoriteStore instance = FavoriteStore._();

  FavoriteStore._();

  Box<dynamic>? _box;

  /// 在 main() 里 await 一次即可，之后同步读写
  Future<void> init() async {
    _box ??= await Hive.openBox<dynamic>(boxName);
  }

  /// 全部收藏（按写入顺序）
  List<FavoriteRoom> all() {
    final box = _box;
    if (box == null) return const [];
    final result = <FavoriteRoom>[];
    for (final key in box.keys) {
      final room = FavoriteRoom.fromMap(box.get(key));
      if (room != null) result.add(room);
    }
    return result;
  }

  /// 只要「特别关注」的那些（主页名片区用）
  List<FavoriteRoom> specialFollowed() => all().where((r) => r.specialFollowed).toList();

  /// 取单条记录，没有则返回 null
  FavoriteRoom? get(LIVE_SITE_E site, int roomId) {
    final box = _box;
    if (box == null || roomId <= 0) return null;
    return FavoriteRoom.fromMap(box.get('${site.name}_$roomId'));
  }

  bool contains(LIVE_SITE_E site, int roomId) {
    final box = _box;
    if (box == null || roomId <= 0) return false;
    return box.containsKey('${site.name}_$roomId');
  }

  /// 是否特别关注。未关注 / 无记录一律 false
  bool isSpecialFollowed(LIVE_SITE_E site, int roomId) => get(site, roomId)?.specialFollowed ?? false;

  Future<void> add(FavoriteRoom room) async {
    final box = _box;
    if (box == null) return;
    await box.put(room.key, room.toMap());
  }

  /// 设置某条记录是否特别关注。
  ///
  /// 记录不存在时直接忽略：特别关注是「关注」之上的附加状态，
  /// 不能凭空创建一份没有主播信息的记录出来。
  Future<void> setSpecialFollowed(LIVE_SITE_E site, int roomId, bool value) async {
    final existing = get(site, roomId);
    if (existing == null) return;
    if (existing.specialFollowed == value) return;
    await add(existing.copyWith(specialFollowed: value));
  }

  Future<void> remove(LIVE_SITE_E site, int roomId) async {
    final box = _box;
    if (box == null) return;
    await box.delete('${site.name}_$roomId');
  }

  // ===== 关注列表的导入 / 导出 =====

  /// 导出全部关注为 JSON 文本
  String exportToJson() {
    final rooms = all().map((r) => r.toMap()).toList();
    return const JsonEncoder.withIndent('  ').convert(rooms);
  }

  /// 从 JSON 文本导入关注，返回 (新增数, 覆盖数, 跳过数)。
  Future<({int added, int updated, int skipped})> importFromJson(String text) async {
    final box = _box;
    if (box == null) return (added: 0, updated: 0, skipped: 0);

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

      final exists = box.containsKey(room.key);
      await box.put(room.key, room.toMap());
      if (exists) {
        updated++;
      } else {
        added++;
      }
    }

    return (added: added, updated: updated, skipped: skipped);
  }
}
