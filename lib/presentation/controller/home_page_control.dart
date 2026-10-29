import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';

import 'package:ym_live_stream/contract/auth_source.dart';
import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/contract/live_source.dart';
import 'package:ym_live_stream/mock/mock_live_source.dart';
import 'package:ym_live_stream/core/route_path.dart';
import 'package:ym_live_stream/features/favorite_store.dart';
import 'package:ym_live_stream/shared/live_site_meta.dart';
import 'package:ym_live_stream/presentation/widgets/room_not_live_card.dart';

enum HomeTab { home, collection, settings, about }

enum LiveStatus { live, offline, unknown, banned }

/// 名片数据。
class CardItemData {
  final String avatarUrl;
  final String userName;
  final LiveStatus status;
  final String roomTitle;

  /// 点名片要能进直播间，所以带上平台和房间号
  final int? roomId;
  final LIVE_SITE_E? site;

  CardItemData({required this.avatarUrl, required this.userName, required this.roomTitle, this.status = LiveStatus.unknown, this.roomId, this.site});
}

class SearchParseResult {
  final bool ok;
  final int? roomId;
  final LiveSiteMeta? site;
  final String? error;

  final bool siteDetectedFromUrl;

  const SearchParseResult._({required this.ok, this.roomId, this.site, this.error, this.siteDetectedFromUrl = false});

  factory SearchParseResult.success(int roomId, LiveSiteMeta site, {bool siteDetectedFromUrl = false}) =>
      SearchParseResult._(ok: true, roomId: roomId, site: site, siteDetectedFromUrl: siteDetectedFromUrl);

  factory SearchParseResult.fail(String error) => SearchParseResult._(ok: false, error: error);
}

/// 进房间前查到的基本信息（内部用）。
class _RoomProbe {
  final LIVE_SHOW_STATUS_E showStatus;
  final String roomName;
  final String ownerName;
  final String ownerProfileUrl;

  const _RoomProbe({required this.showStatus, required this.roomName, required this.ownerName, required this.ownerProfileUrl});
}

class BlockedRoomInfo {
  /// 是否属于「未开播 / 封禁」这类业务状态（true 走信息卡，false 走报错弹窗）
  final bool isNotLive;

  final LIVE_SITE_E site;
  final int roomId;

  /// 报错文案（isNotLive == false 时用）
  final String message;

  /// 直播状态（isNotLive == true 时用）
  final LIVE_SHOW_STATUS_E showStatus;

  final String roomName;
  final String ownerName;
  final String ownerProfileUrl;

  const BlockedRoomInfo._({
    required this.isNotLive,
    required this.site,
    required this.roomId,
    this.message = '',
    this.showStatus = LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN,
    this.roomName = '',
    this.ownerName = '',
    this.ownerProfileUrl = '',
  });

  factory BlockedRoomInfo.notLive({
    required LIVE_SITE_E site,
    required int roomId,
    required LIVE_SHOW_STATUS_E showStatus,
    required String roomName,
    required String ownerName,
    required String ownerProfileUrl,
  }) =>
      BlockedRoomInfo._(
        isNotLive: true,
        site: site,
        roomId: roomId,
        showStatus: showStatus,
        roomName: roomName,
        ownerName: ownerName,
        ownerProfileUrl: ownerProfileUrl,
      );

  factory BlockedRoomInfo.error({required LIVE_SITE_E site, required int roomId, required String message}) =>
      BlockedRoomInfo._(isNotLive: false, site: site, roomId: roomId, message: message);
}

class _RoomStatusProbe {
  final LiveStatus status;
  final String roomName;
  final String ownerName;
  final String ownerProfileUrl;

  const _RoomStatusProbe({
    required this.status,
    this.roomName = '',
    this.ownerName = '',
    this.ownerProfileUrl = '',
  });
}

class HomeController extends GetxController {
  final selectedTab = HomeTab.home.obs;

  final List<NavigationItem> navItems = const [
    NavigationItem(icon: Remix.home_line, activeIcon: Remix.home_fill, title: '主页'),
    NavigationItem(icon: Remix.heart_line, activeIcon: Remix.heart_fill, title: '关注'),
    NavigationItem(icon: Remix.settings_line, activeIcon: Remix.settings_fill, title: '设置'),
    NavigationItem(icon: Remix.information_line, activeIcon: Remix.information_fill, title: '关于'),
  ];

  static const int primaryNavCount = 3;

  final specialCardList = <CardItemData>[].obs;

  final followedCardList = <CardItemData>[].obs;

  /// 正在刷新开播状态（两个刷新按钮共用）
  final isRefreshingStatus = false.obs;

  /// 取某个平台的后端实现；没注册就用 mock 兜底。
  LiveSource _sourceOf(LIVE_SITE_E site) =>
      LiveSourceRegistry.find(site) ?? _mockFor(site);

  static final Map<LIVE_SITE_E, LiveSource> _mockCache = {};

  static LiveSource _mockFor(LIVE_SITE_E site) =>
      _mockCache.putIfAbsent(site, () => MockLiveSource(site));

  /// 避免两个按钮同时点出两轮刷新
  bool _refreshBusy = false;

  @override
  void onInit() {
    super.onInit();
    _loadFavorites();
    unawaited(refreshLiveStatus());
    unawaited(loadBilibiliLoginStateOnStartup());
  }

  /// 从 Hive 读关注记录，分别铺到「主页特别关注」和「关注页全量」两个列表
  void _loadFavorites() {
    final all = FavoriteStore.instance.all();

    specialCardList.value = all.where((f) => f.specialFollowed).map(_toCard).toList();
    followedCardList.value = all.map(_toCard).toList();

    _sortCardsByStatus();
  }

  /// 存储记录 → 名片数据（状态先给 unknown，等下面查）
  static CardItemData _toCard(FavoriteRoom f, {LiveStatus status = LiveStatus.unknown}) => CardItemData(
        avatarUrl: f.ownerProfileUrl,
        userName: f.ownerName,
        roomTitle: f.roomName,
        status: status,
        roomId: f.roomId,
        site: f.site,
      );

  Future<void> refreshLiveStatus() async {
    if (_refreshBusy) return;

    final favorites = FavoriteStore.instance.all();
    if (favorites.isEmpty) {
      specialCardList.value = [];
      followedCardList.value = [];
      return;
    }

    _refreshBusy = true;
    isRefreshingStatus.value = true;
    try {
      final probeMap = <String, _RoomStatusProbe>{};
      await Future.wait(
        favorites.map((f) async {
          probeMap[f.key] = await _queryStatusAndMeta(f);
        }),
      );

      for (final f in favorites) {
        final probe = probeMap[f.key];
        if (probe == null) continue;
        final merged = f.copyWithMeta(roomName: probe.roomName, ownerName: probe.ownerName, ownerProfileUrl: probe.ownerProfileUrl);
        if (merged != null) await FavoriteStore.instance.add(merged);
      }

      CardItemData toCardWithProbe(FavoriteRoom f) {
        final probe = probeMap[f.key];
        return CardItemData(
          avatarUrl: (probe?.ownerProfileUrl.isNotEmpty ?? false) ? probe!.ownerProfileUrl : f.ownerProfileUrl,
          userName: (probe != null && probe.ownerName.isNotEmpty) ? probe.ownerName : f.ownerName,
          roomTitle: (probe != null && probe.roomName.isNotEmpty) ? probe.roomName : f.roomName,
          status: probe?.status ?? LiveStatus.unknown,
          roomId: f.roomId,
          site: f.site,
        );
      }

      specialCardList.value = favorites.where((f) => f.specialFollowed).map(toCardWithProbe).toList();
      followedCardList.value = favorites.map(toCardWithProbe).toList();
      _sortCardsByStatus();
    } finally {
      isRefreshingStatus.value = false;
      _refreshBusy = false;
    }
  }

  Future<_RoomStatusProbe> _queryStatusAndMeta(FavoriteRoom f) async {
    try {
      final info = await _sourceOf(f.site).fetchRoomBrief(f.roomId);
      if (info == null) return const _RoomStatusProbe(status: LiveStatus.unknown);

      return _RoomStatusProbe(
        status: _mapStatus(info.show_status),
        roomName: info.room_name ?? '',
        ownerName: info.owner_name ?? '',
        ownerProfileUrl: info.owner_profile_url ?? '',
      );
    } catch (_) {
      return const _RoomStatusProbe(status: LiveStatus.unknown);
    }
  }

  static LiveStatus _mapStatus(LIVE_SHOW_STATUS_E? status) {
    switch (status) {
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE:
        return LiveStatus.live;
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE:
        return LiveStatus.offline;
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN:
        return LiveStatus.banned;
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN:
      case null:
        return LiveStatus.unknown;
    }
  }

  List<({LIVE_SITE_E site, String title, List<CardItemData> cards})> get followedGroups {
    final all = followedCardList.value;

    final result = <({LIVE_SITE_E site, String title, List<CardItemData> cards})>[];
    for (final meta in LiveSites.all) {
      final cards = all.where((c) => c.site == meta.site).toList();
      if (cards.isEmpty) continue;
      result.add((site: meta.site, title: meta.displayName, cards: cards));
    }
    return result;
  }

  final searchTextController = TextEditingController();

  /// 下拉框当前选中的平台，默认哔哩哔哩
  final selectedSite = LiveSites.defaultSite.obs;

  /// 解析失败时的提示（给输入框下方用）
  final searchError = RxnString();

  final isSearching = false.obs;

  void reloadCardsFromStore() => _rebuildCardsFromStore();

  void switchTab(HomeTab tab) {
    selectedTab.value = tab;
  }

  void selectSite(LiveSiteMeta meta) {
    selectedSite.value = meta;
    searchError.value = null;
  }

  @override
  void onClose() {
    searchTextController.dispose();
    super.onClose();
  }

  Future<SearchParseResult> parseSearchInput(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return SearchParseResult.fail('请输入房间号或直播间链接');
    }

    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      final site = selectedSite.value;
      if (!site.isValidRoomId(trimmed)) {
        return SearchParseResult.fail(site.roomIdRuleHint);
      }
      return SearchParseResult.success(int.parse(trimmed), site);
    }

    if (_looksLikeUrl(trimmed)) {
      final normalized = _normalizeUrl(trimmed);
      final uri = Uri.tryParse(normalized);
      if (uri == null || uri.host.isEmpty) {
        return SearchParseResult.fail('链接格式不正确');
      }

      final detected = LiveSites.detectByUrl(normalized);
      if (detected == null) {
        return SearchParseResult.fail('无法识别链接所属平台：${uri.host}');
      }

      var roomId = _extractRoomIdFromUri(uri);

      roomId = (await _sourceOf(detected.site).resolveRoomIdFromShareText(normalized))?.toString() ?? roomId;

      if (roomId == null) {
        return SearchParseResult.fail('链接中没有找到房间号');
      }
      if (!detected.isValidRoomId(roomId)) {
        return SearchParseResult.fail('${detected.roomIdRuleHint}，链接中解析到的是 $roomId');
      }

      return SearchParseResult.success(int.parse(roomId), detected, siteDetectedFromUrl: detected.site != selectedSite.value.site);
    }

    for (final meta in LiveSites.all) {
      final source = _sourceOf(meta.site);
      final shareUrl = source.extractUrlFromText(trimmed);
      if (shareUrl == null) continue;

      final rid = await source.resolveRoomIdFromShareText(shareUrl);
      if (rid == null) {
        return SearchParseResult.fail('没能从这段分享内容里解析出${meta.displayName}房间号');
      }
      final roomId = rid.toString();
      if (!meta.isValidRoomId(roomId)) {
        return SearchParseResult.fail('${meta.roomIdRuleHint}，解析到的是 $roomId');
      }
      return SearchParseResult.success(rid, meta, siteDetectedFromUrl: meta.site != selectedSite.value.site);
    }

    return SearchParseResult.fail('请输入纯数字房间号或直播间链接');
  }

  Future<bool> submitSearch() async {
    final result = await parseSearchInput(searchTextController.text);
    if (!result.ok) {
      searchError.value = result.error;
      return false;
    }

    searchError.value = null;

    if (result.siteDetectedFromUrl && result.site != null) {
      selectedSite.value = result.site!;
    }

    final site = result.site!;
    final roomId = result.roomId!;

    isSearching.value = true;
    try {
      await openLiveRoom(site.site, roomId);
      return true;
    } finally {
      isSearching.value = false;
    }
  }

  Future<void> openLiveRoom(LIVE_SITE_E site, int roomId) async {
    if (isOpeningRoom.value) return;
    isOpeningRoom.value = true;

    try {
      final probe = await _probeRoom(site, roomId);

      if (probe == null) {
        await _showBlockedDialog(
          BlockedRoomInfo.error(
            site: site,
            roomId: roomId,
            message: '获取直播间信息失败，请检查网络或房间号是否正确',
          ),
        );
        return;
      }

      final status = probe.showStatus;
      if (status == LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE) {
        await _enterRoomPage(site, roomId);
        return;
      }

      await _showBlockedDialog(
        BlockedRoomInfo.notLive(
          site: site,
          roomId: roomId,
          showStatus: status,
          roomName: probe.roomName,
          ownerName: probe.ownerName,
          ownerProfileUrl: probe.ownerProfileUrl,
        ),
      );
    } finally {
      isOpeningRoom.value = false;
    }
  }

  /// 正在打开直播间（查询状态 + 跳转），用于卡片点击的防抖
  final isOpeningRoom = false.obs;

  Future<void> _showBlockedDialog(BlockedRoomInfo data) async {
    if (data.isNotLive) {
      await Get.dialog<void>(
        RoomNotLiveCard(data: data, onClose: () => Get.back()),
        barrierDismissible: false,
      );
      _rebuildCardsFromStore();
      return;
    }

    await Get.dialog<void>(
      AlertDialog(
        title: const Text('无法进入直播间', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(data.message, style: const TextStyle(fontSize: 14)),
        actions: [TextButton(onPressed: () => Get.back(), child: const Text('知道了'))],
      ),
      barrierDismissible: false,
    );
  }

  /// 真正跳转到播放页
  Future<void> _enterRoomPage(LIVE_SITE_E site, int roomId) async {
    await Get.toNamed(
      RoutePath.p_liveroom,
      arguments: LiveRoomArgs(roomId: roomId, site: site),
    );
    _rebuildCardsFromStore();
  }

  /// 查房间的基本信息 + 开播状态。拿不到返回 null。
  Future<_RoomProbe?> _probeRoom(LIVE_SITE_E site, int roomId) async {
    try {
      final info = await _sourceOf(site).fetchRoomBrief(roomId).timeout(_kProbeTimeout);
      if (info == null) return null;
      return _RoomProbe(
        showStatus: info.show_status ?? LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN,
        roomName: info.room_name ?? '',
        ownerName: info.owner_name ?? '',
        ownerProfileUrl: info.owner_profile_url ?? '',
      );
    } catch (e) {
      Get.log('[HomeController] 查询直播间 $site/$roomId 失败: $e', isError: true);
      return null;
    }
  }

  static const _kProbeTimeout = Duration(seconds: 10);

  void _rebuildCardsFromStore() {
    final known = <String, LiveStatus>{};
    for (final card in [...followedCardList.value, ...specialCardList.value]) {
      final roomId = card.roomId;
      final site = card.site;
      if (roomId == null || site == null) continue;
      known['${site.name}_$roomId'] = card.status;
    }

    final all = FavoriteStore.instance.all();
    specialCardList.value = all
        .where((f) => f.specialFollowed)
        .map((f) => _toCard(f, status: known[f.key] ?? LiveStatus.unknown))
        .toList();
    followedCardList.value = all.map((f) => _toCard(f, status: known[f.key] ?? LiveStatus.unknown)).toList();
    _sortCardsByStatus();
  }

  void _sortCardsByStatus() {
    specialCardList.value = _sorted(specialCardList.value);
    followedCardList.value = _sorted(followedCardList.value);
  }

  /// 按状态稳定排序一份列表，返回新列表（不改入参）
  static List<CardItemData> _sorted(List<CardItemData> source) {
    final sorted = source.toList();
    final indexOf = <CardItemData, int>{};
    for (var i = 0; i < sorted.length; i++) {
      indexOf[sorted[i]] = i;
    }
    sorted.sort((a, b) {
      final byStatus = _statusRank(a.status).compareTo(_statusRank(b.status));
      if (byStatus != 0) return byStatus;
      return (indexOf[a] ?? 0).compareTo(indexOf[b] ?? 0);
    });
    return sorted;
  }

  static int _statusRank(LiveStatus status) {
    switch (status) {
      case LiveStatus.live:
        return 0;
      case LiveStatus.unknown:
        return 1;
      case LiveStatus.offline:
        return 2;
      case LiveStatus.banned:
        return 3;
    }
  }

  bool _looksLikeUrl(String text) {
    if (text.startsWith('http://') || text.startsWith('https://')) return true;
    return RegExp(r'^[\w-]+(\.[\w-]+)+([/?#].*)?$').hasMatch(text);
  }

  String _normalizeUrl(String text) => text.startsWith('http://') || text.startsWith('https://') ? text : 'https://$text';

  String? _extractRoomIdFromUri(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty);
    for (final segment in segments.toList().reversed) {
      if (RegExp(r'^\d+$').hasMatch(segment)) return segment;
    }
    for (final key in ['room_id', 'roomId', 'rid']) {
      final value = uri.queryParameters[key];
      if (value != null && RegExp(r'^\d+$').hasMatch(value)) return value;
    }
    return null;
  }

  /// 设置页当前选中的分类（0 常规 / 1 哔哩哔哩 / 2 斗鱼 / 3 抖音）
  final settingsSection = 0.obs;

  /// 关注列表导入导出是否正在执行（防连点 + 按钮转圈）
  final isExportingFollows = false.obs;
  final isImportingFollows = false.obs;

  /// B 站登录进行中（二维码弹窗展示期间为 true）
  final isBilibiliLoggingIn = false.obs;

  /// B 站登录态摘要：已登录时显示昵称或用户 id，未登录显示空串
  final bilibiliLoginLabel = ''.obs;

  Future<void> refreshBilibiliLoginState() async {
    final auth = AuthSourceRegistry.find(LIVE_SITE_E.LIVE_SITE_BILIBILI);

    if (auth == null) {
      bilibiliLoginLabel.value = '';
      return;
    }

    try {
      final account = await auth.currentAccount();
      if (account == null) {
        bilibiliLoginLabel.value = '';
        return;
      }

      final uid = account.userId ?? '';
      final nickname = account.nickname ?? '';
      if (nickname.isNotEmpty) {
        bilibiliLoginLabel.value = '已登录 ($nickname)';
      } else if (uid.isNotEmpty) {
        bilibiliLoginLabel.value = '已登录 (UID $uid)';
      } else {
        bilibiliLoginLabel.value = '已登录';
      }
    } catch (_) {
      bilibiliLoginLabel.value = '';
    }
  }

  Future<void> loadBilibiliLoginStateOnStartup() async {
    await refreshBilibiliLoginState();
  }

  Future<({bool ok, String message})> importFollows() async {
    if (isImportingFollows.value) return (ok: false, message: '正在导入中');
    isImportingFollows.value = true;
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: '选择关注列表文件',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null) {
        return (ok: false, message: '');
      }

      final text = await _readPickedFile(picked);
      if (text == null) {
        return (ok: false, message: '无法读取文件内容');
      }

      final result = await FavoriteStore.instance.importFromJson(text);

      _rebuildCardsFromStore();

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
      isImportingFollows.value = false;
    }
  }

  Future<String?> _readPickedFile(PlatformFile file) async {
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      final f = File(path);
      if (await f.exists()) {
        return f.readAsString();
      }
    }

    try {
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 导出关注列表：选择保存位置 → 写入 JSON 文件。
  Future<({bool ok, String message})> exportFollows() async {
    if (isExportingFollows.value) return (ok: false, message: '正在导出中');
    isExportingFollows.value = true;
    try {
      final rooms = FavoriteStore.instance.all();
      if (rooms.isEmpty) {
        return (ok: false, message: '还没有关注任何直播间');
      }

      final json = FavoriteStore.instance.exportToJson();

      final saved = await FilePicker.saveFile(
        dialogTitle: '导出关注列表',
        fileName: 'ym_live_stream_follows.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: utf8.encode(json),
      );
      if (saved == null) {
        return (ok: false, message: '');
      }

      final path = saved.scheme == 'file' ? saved.toFilePath() : saved.toString();

      return (ok: true, message: '已导出 ${rooms.length} 条关注到 $path');
    } catch (e) {
      return (ok: false, message: '导出失败：$e');
    } finally {
      isExportingFollows.value = false;
    }
  }
}

/// 导航栏配置数据模型：带选中态图标
class NavigationItem {
  final IconData icon;
  final IconData activeIcon;
  final String title;

  const NavigationItem({required this.icon, required this.activeIcon, required this.title});
}
