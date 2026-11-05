import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';

import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/contract/live_source.dart';
import 'package:ym_live_stream/core/route_path.dart';
import 'package:ym_live_stream/shared/live_site_meta.dart';
import 'package:ym_live_stream/presentation/app_router.dart';
import 'package:ym_live_stream/presentation/widgets/room_not_live_card.dart';

import 'favorites_controller.dart';
import 'live_source_locator.dart';

/// 【迁移期的兼容出口】
///
/// `LiveStatus` / `CardItemData` 已经搬到 favorites_controller.dart，
/// 但 home_page.dart、room_not_live_card.dart 等处原来都从这里 import 它们。
/// 为了这一轮不改动那几处 import（降低一次性改坏的风险），这里转出去。
///
/// 等整个迁移收尾时，把这两行删掉、各文件改成直接 import
/// favorites_controller.dart 即可 —— 那时候再统一清理。
export 'favorites_controller.dart' show LiveStatus, CardItemData;

/// 左侧导航栏的页面。
///
/// 【关于放在最后】它是「设置」之外单开的一页，固定在导航栏最底部
/// （见 home_page.dart 的 _buildNavRail），不跟随上面三个主页面一起往上排。
enum HomeTab { home, collection, settings, about }

/// 搜索解析结果。
/// 用对象而不是 bool，因为要区分：
/// “解析成功”、“格式不对”、“平台不匹配但可以自动纠正”。
class SearchParseResult {
  final bool ok;

  /// 房间标识（字符串，快手这类平台会是字母 id）
  final String? roomId;
  final LiveSiteMeta? site;
  final String? error;

  /// 输入的是 URL 且识别出的平台与下拉框当前选择不一致时，
  /// 为 true（需求：允许自动识别并覆盖下拉框）
  final bool siteDetectedFromUrl;

  const SearchParseResult._({required this.ok, this.roomId, this.site, this.error, this.siteDetectedFromUrl = false});

  factory SearchParseResult.success(String roomId, LiveSiteMeta site, {bool siteDetectedFromUrl = false}) =>
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

/// 「这个房间进不去」时给页面用的一份数据。
///
/// 两种形态：
///   * notLive —— 未开播 / 被封禁：弹带主播信息的信息卡，卡上能关注、特别关注；
///   * error   —— 连信息都没拿到：只能弹一句报错。
class BlockedRoomInfo {
  /// 是否属于「未开播 / 封禁」这类业务状态（true 走信息卡，false 走报错弹窗）
  final bool isNotLive;

  final LIVE_SITE_E site;
  final String roomId;

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
    required String roomId,
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

  factory BlockedRoomInfo.error({required LIVE_SITE_E site, required String roomId, required String message}) =>
      BlockedRoomInfo._(isNotLive: false, site: site, roomId: roomId, message: message);
}

class HomeController extends ChangeNotifier {
  // ===================== 左侧导航 =====================
  HomeTab _selectedTab = HomeTab.home;
  HomeTab get selectedTab => _selectedTab;
  set selectedTab(HomeTab v) {
    _selectedTab = v;
    notifyListeners();
  }

  final List<NavigationItem> navItems = const [
    NavigationItem(icon: Remix.home_line, activeIcon: Remix.home_fill, title: '主页'),
    // 原来是「收藏」，统一改叫「关注」（里面是「我的关注」）
    NavigationItem(icon: Remix.heart_line, activeIcon: Remix.heart_fill, title: '关注'),
    NavigationItem(icon: Remix.settings_line, activeIcon: Remix.settings_fill, title: '设置'),
    // 关于页固定贴在导航栏最底部（见 home_page.dart 的 _buildNavRail）
    NavigationItem(icon: Remix.information_line, activeIcon: Remix.information_fill, title: '关于'),
  ];

  /// 导航栏里「主页面」的数量（主页/关注/设置）。
  ///
  /// 它们用 IndexedStack 保状态，索引要和 HomeTab 的枚举顺序一一对应；
  /// 「关于」是第 4 项，单独渲染，不参与这个 IndexedStack ——
  /// 否则给前三个页面各加一个 index 之外的占位，会影响已有页面的状态保持。
  static const int primaryNavCount = 3;

  // ===================== 关注列表（已迁走）=====================
  //
  // 名片列表、开播状态查询、排序、按平台分组，全部搬到了
  // `favorites_controller.dart`（FavoritesController，ChangeNotifier），
  // 由 FavoritesScope 挂在 App 根部 —— 后面的录播页也要用同一份数据，
  // 两页各建一个实例会让请求翻倍、状态还会不一致。
  //
  // 这里只留一个引用：进房回来 / 弹窗关掉之后，需要通知它按存储重建名片。
  // 由页面在创建时注入（见 HomePage.initState），HomeController 不反向依赖它。
  FavoritesController? favorites;

  /// 取某个平台的后端实现。
  ///
  /// 【为什么委托给 LiveSourceLocator】收藏列表查询也用它，而那部分已经搬到
  /// FavoritesController 里了。两边各自持一份 mock 缓存会让同一平台建出
  /// 两个 MockLiveSource 实例，假数据不一致。统一走那个单例。
  LiveSource _sourceOf(LIVE_SITE_E site) => LiveSourceLocator.of(site);

  // ===================== 搜索区 =====================
  final searchTextController = TextEditingController();

  /// 下拉框当前选中的平台，默认哔哩哔哩
  LiveSiteMeta _selectedSite = LiveSites.defaultSite;
  LiveSiteMeta get selectedSite => _selectedSite;
  set selectedSite(LiveSiteMeta v) {
    _selectedSite = v;
    notifyListeners();
  }

  /// 解析失败时的提示（给输入框下方用）
  String? _searchError;
  String? get searchError => _searchError;
  set searchError(String? v) {
    _searchError = v;
    notifyListeners();
  }

  bool _isSearching = false;
  bool get isSearching => _isSearching;
  set isSearching(bool v) {
    _isSearching = v;
    notifyListeners();
  }

  void switchTab(HomeTab tab) {
    selectedTab = tab;
    // 页面跳转逻辑留空：主页/收藏/设置由外层 IndexedStack 切换，
    // 若改成独立路由，在这里补 context.go(...) 即可。
  }

  void selectSite(LiveSiteMeta meta) {
    selectedSite = meta;
    searchError = null;
  }

  @override
  void dispose() {
    searchTextController.dispose();
    super.dispose();
  }

  // ===================== 搜索解析 =====================
  /// 解析输入框内容。
  ///
  /// 规则（按需求）：
  /// 1. 纯数字 -> 用“当前下拉框选中的平台”校验房间号长度
  /// 2. URL     -> 自动识别平台；识别成功就覆盖下拉框选择，
  ///               识别不出则回落到当前下拉框选择
  /// 3. 其它    -> 失败
  ///
  /// 返回对象而不是 bool，避免出现“返回成功但 roomId 没拿到”的情况。
  ///
  /// 【App 分享文本也算第 2 种】用户从手机 App 复制过来的是整段话：
  ///   抖音：`1- #在抖音，记录美好生活#【xxx】正在直播…… https://v.douyin.com/l_VT4cS1IM8/ 7@0.com :9pm`
  ///   B 站：`【闲聊-哔哩哔哩直播】 https://b23.tv/8P8sN3S`
  /// 它们不是「看起来像 URL」（不以 http 开头），但里面有短链。
  /// 短链必须先联网跳转（读响应头 Location）才能知道房间号，所以这里是异步的。
  Future<SearchParseResult> parseSearchInput(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return SearchParseResult.fail('请输入房间号或直播间链接');
    }

    // ---------- 情况 1：纯数字房间号 ----------
    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      final site = selectedSite;
      if (!site.isValidRoomId(trimmed)) {
        return SearchParseResult.fail(site.roomIdRuleHint);
      }
      // 直接用字符串，不再转 int（快手这类平台的 id 带字母，不能统一转数字）
      return SearchParseResult.success(trimmed, site);
    }

    // ---------- 情况 1b：字母房间标识 ----------
    //
    // 字母 id 怎么用，交给各平台自己决定（resolveRoomIdFromAlias）：
    //   * 虎牙 `chuhe` → 拉一次房间页换成数字 profileRoom；
    //     换不出来说明主播不存在，报错；
    //   * 快手 `3xz96kaifhw8ec4` → 原样返回自己（这个 id 本身就能请求）。
    //
    // 所以这里只要「拿到什么用什么，拿不到就报错」，不需要关心平台差异。
    if (selectedSite.allowAlphaRoomId && selectedSite.isValidRoomId(trimmed)) {
      final site = selectedSite;
      final resolved = (await _sourceOf(site.site).resolveRoomIdFromAlias(trimmed))?.trim();
      if (LiveRoomArgs.isValidRoomId(resolved)) {
        return SearchParseResult.success(resolved!, site);
      }
      return SearchParseResult.fail('${site.displayName} 找不到主播「$trimmed」，请检查房间号是否正确');
    }

    // ---------- 情况 2：URL ----------
    if (_looksLikeUrl(trimmed)) {
      final normalized = _normalizeUrl(trimmed);
      final uri = Uri.tryParse(normalized);
      if (uri == null || uri.host.isEmpty) {
        return SearchParseResult.fail('链接格式不正确');
      }

      // 自动识别平台并覆盖下拉框
      final detected = LiveSites.detectByUrl(normalized);
      if (detected == null) {
        return SearchParseResult.fail('无法识别链接所属平台：${uri.host}');
      }

      var roomId = _extractRoomIdFromUri(uri, allowAlpha: detected.allowAlphaRoomId);

      // 【短链一律交给平台自己的解析器】
      // 抖音 v.douyin.com/xxx、B 站 b23.tv/xxx 的路径里都不是房间号，
      // 必须联网跟随跳转才能拿到（见各平台 LiveSource 实现）。
      // 已经是直播间直链时解析器会直接返回，不额外发请求。
      //
      // 注意：解析器的结果优先于路径里抠出来的数字 ——
      // 抖音 reflow/<id> 里的 id 是真实 room_id，拿去请求会 404，不能用。
      roomId = (await _sourceOf(detected.site).resolveRoomIdFromShareText(normalized))?.toString() ?? roomId;

      if (roomId == null) {
        return SearchParseResult.fail('链接中没有找到房间号');
      }
      if (!detected.isValidRoomId(roomId)) {
        return SearchParseResult.fail('${detected.roomIdRuleHint}，链接中解析到的是 $roomId');
      }

      final fromUrl = detected.site != selectedSite.site;

      // 【别名链接】`huya.com/chuhe` 的路径是主播别名，换成平台认可的房间标识。
      // 数字房间号不用走这一步（上面 isValidRoomId 已经放行）。
      if (!RegExp(r'^\d+$').hasMatch(roomId)) {
        if (!detected.allowAlphaRoomId) {
          return SearchParseResult.fail('${detected.roomIdRuleHint}，链接中解析到的是 $roomId');
        }
        final resolved = await _sourceOf(detected.site).resolveRoomIdFromAlias(roomId);
        if (!LiveRoomArgs.isValidRoomId(resolved)) {
          return SearchParseResult.fail('${detected.displayName} 找不到主播「$roomId」，请检查链接是否正确');
        }
        roomId = resolved!.trim();
      }

      return SearchParseResult.success(roomId, detected, siteDetectedFromUrl: fromUrl);
    }

    // ---------- 情况 2b / 2c：App 分享文本（抖音 / B 站） ----------
    //
    // 分享出来的是整段话，形如：
    //   抖音：`1- #在抖音... https://v.douyin.com/xxx/ 7@0.com :9pm`
    //   B 站：`【闲聊-哔哩哔哩直播】 https://b23.tv/8P8sN3S`
    // 都不是「看起来像 URL」（不以 http 开头），但里面有短链。
    //
    // 【不再按平台写两段】对每个平台问一次「这段文字里有你的链接吗」，
    // 有就交给它自己去解析。以后新增平台不用动这里。
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
      return SearchParseResult.success(roomId, meta, siteDetectedFromUrl: meta.site != selectedSite.site);
    }

    // ---------- 情况 3：无法识别 ----------
    // 虎牙允许字母别名，所以提示里区分一下，避免用户以为输错了
    if (selectedSite.allowAlphaRoomId) {
      return SearchParseResult.fail('请输入房间号、主播别名或直播间链接');
    }
    return SearchParseResult.fail('请输入纯数字房间号或直播间链接');
  }

  /// 单击放大镜：解析并按平台跳转。
  /// 平台层解析函数由你之后接入 —— 这里只负责拿到 (roomId, site) 并跳转。
  Future<bool> submitSearch() async {
    final result = await parseSearchInput(searchTextController.text);
    if (!result.ok) {
      searchError = result.error;
      return false;
    }

    searchError = null;

    // 自动识别到的平台覆盖下拉框选择
    if (result.siteDetectedFromUrl && result.site != null) {
      selectedSite = result.site!;
    }

    final site = result.site!;
    final roomId = result.roomId!;

    // TODO: 调用对应平台的解析函数（斗鱼/哔哩哔哩/抖音各不相同），
    //       现在只把参数交给跳转逻辑，具体请求在 LiveStreamController 里做。
    isSearching = true;
    try {
      await openLiveRoom(site.site, roomId);
      return true;
    } finally {
      isSearching = false;
    }
  }

  /// 进直播间前的状态检查完成后，要弹的信息卡数据。
  ///
  /// 跳转到直播间。
  ///
  /// 【关键】这里先查一次开播状态，**确认能播才跳转**。
  /// 之前是无条件 Get.toNamed 进播放页，再由播放页的 controller 发现未开播、
  /// 弹窗、再退回来 —— 用户会看到播放页闪一下（甚至看到「正在连接直播间」），
  /// 体验很怪。现在把判断提到跳转之前，未开播的压根不进播放页。
  Future<void> openLiveRoom(LIVE_SITE_E site, String roomId) async {
    // 已在查询中就不再重复发起（用户连点卡片）
    if (isOpeningRoom) return;
    isOpeningRoom = true;

    try {
      final probe = await _probeRoom(site, roomId);

      if (probe == null) {
        // 连基本信息都没拿到：确实进不去，弹报错
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
        // 正常开播：真的进播放页
        await _enterRoomPage(site, roomId);
        return;
      }

      // 未开播 / 被封禁 / 状态未知：停在首页弹信息卡，不进播放页
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
      isOpeningRoom = false;
    }
  }

  /// 正在打开直播间（查询状态 + 跳转），用于卡片点击的防抖
  bool _isOpeningRoom = false;
  bool get isOpeningRoom => _isOpeningRoom;
  set isOpeningRoom(bool v) {
    _isOpeningRoom = v;
    notifyListeners();
  }

  /// 在首页弹出「进不去」的提示：未开播弹信息卡，其余弹报错。
  ///
  /// 放在 controller 里弹而不是让页面监听状态：
  /// HomePage 是 StatelessWidget，没有可靠的生命周期去挂 ever 监听；
  /// 而这个动作本来就是「点卡片的后续」，由发起方直接 await 最直白。
  ///
  /// 【从 Get.dialog 换成 showDialog】GetX 的 dialog 依赖 GetMaterialApp
  /// 提供的 Navigator/Overlay，路由换到 MaterialApp.router 之后用不了
  /// （表现为弹窗根本不出现）。改用 AppRouter.rootNavigatorKey 拿全局 context。
  Future<void> _showBlockedDialog(BlockedRoomInfo data) async {
    // controller 里没有 BuildContext，只能从根 Navigator 拿一个
    final context = AppRouter.rootNavigatorKey.currentContext;
    if (context == null) return;

    if (data.isNotLive) {
      await showDialog<void>(
        context: context,
        // 卡上有按钮，点外面误关会让人以为没点到
        barrierDismissible: false,
        builder: (dialogContext) => RoomNotLiveCard(
          data: data,
          // 卡片上的关闭按钮：关掉这个 dialog 自己
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      );
      // 弹窗关闭后刷新两张卡片的关注状态（用户可能在卡上关注/取消了）
      favorites?.reloadFromStore();
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法进入直播间', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(data.message, style: const TextStyle(fontSize: 14)),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
      ),
    );
  }

  /// 真正跳转到播放页
  ///
  /// 【从 Get.toNamed 换成 GoRouter.push】
  /// 路由已经交给 go_router，controller 里没有 BuildContext，
  /// 所以用全局 router 实例 `AppRouter.router.push` push 一整页
  /// （用 push 而不是 go：从直播间返回时要能退回首页，栈要留一层）。
  /// 房间参数通过 `extra` 传，AppRouter 那边按 extra 解析。
  Future<void> _enterRoomPage(LIVE_SITE_E site, String roomId) async {
    await AppRouter.router.push(
      RoutePath.p_liveroom,
      extra: LiveRoomArgs(roomId: roomId, site: site),
    );
    // 回到首页重读一遍：房间里可能刚关注 / 取消关注 / 改过特别关注，
    // 不刷新列表还是旧的。特别注意：变成「普通关注」的房间要从名片区消失，
    // 变成「特别关注」的房间要出现 —— 都靠这次重建。
    // 这里刻意不重新下查开播状态（那是一次次网络请求），沿用已知状态即可，
    // 想看最新状态点两个「刷新」按钮。
    favorites?.reloadFromStore();
  }

  /// 查房间的基本信息 + 开播状态。拿不到返回 null。
  Future<_RoomProbe?> _probeRoom(LIVE_SITE_E site, String roomId) async {
    try {
      // 进房前只判断「能不能播」+ 取主播信息，不需要完整流列表，
      // 所以用轻量的 fetchRoomBrief；真正的流地址等进了播放页再按清晰度单独取。
      final info = await _sourceOf(site).fetchRoomBrief(roomId).timeout(_kProbeTimeout);
      if (info == null) return null;
      return _RoomProbe(
        showStatus: info.show_status ?? LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN,
        roomName: info.room_name ?? '',
        ownerName: info.owner_name ?? '',
        ownerProfileUrl: info.owner_profile_url ?? '',
      );
    } catch (e) {
      debugPrint('[HomeController] 查询直播间 $site/$roomId 失败: $e');
      return null;
    }
  }

  /// 状态查询超时。比播放页的 15s 短一些：用户点了卡片在等，
  /// 太久没反应不如直接告诉他查不到。
  static const _kProbeTimeout = Duration(seconds: 10);

  // ===================== 内部工具 =====================

  bool _looksLikeUrl(String text) {
    if (text.startsWith('http://') || text.startsWith('https://')) return true;
    // 形如 live.bilibili.com/732 这种省略协议的输入
    return RegExp(r'^[\w-]+(\.[\w-]+)+([/?#].*)?$').hasMatch(text);
  }

  String _normalizeUrl(String text) => text.startsWith('http://') || text.startsWith('https://') ? text : 'https://$text';

  /// 从 URL 中提取房间号。
  /// 取“路径中最后一个纯数字段”，这样
  /// - live.bilibili.com/732              -> 732
  /// - live.douyin.com/932584152016       -> 932584152016
  /// - douyin.com/follow/live/202756377804-> 202756377804
  /// 都能正确拿到。
  ///
  /// [allowAlpha] 为 true 时（虎牙 / 快手）额外把「数字字母混排的路径段」
  /// 当作房间标识返回，例如：
  /// - huya.com/chuhe                -> chuhe（主播别名，上层会转成数字）
  /// - live.kuaishou.com/u/3xvsgfu2yrry8gu -> 3xvsgfu2yrry8gu（本身就是 id）
  String? _extractRoomIdFromUri(Uri uri, {bool allowAlpha = false}) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    for (final segment in segments.reversed) {
      if (RegExp(r'^\d+$').hasMatch(segment)) return segment;
    }
    // 有些平台的房间号在查询参数里
    for (final key in ['room_id', 'roomId', 'rid']) {
      final value = uri.queryParameters[key];
      if (value != null && RegExp(r'^\d+$').hasMatch(value)) return value;
    }
    // 字母数字混排的房间标识（虎牙别名 / 快手 id）
    // 注意：不能用 [A-Za-z] 强制字母开头 —— 快手是数字开头（3xvsgfu2yrry8gu）
    if (allowAlpha) {
      for (final segment in segments.reversed) {
        if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{2,31}$').hasMatch(segment) && !RegExp(r'^\d+$').hasMatch(segment)) {
          return segment;
        }
      }
    }
    return null;
  }

  // ===================== 设置页（已迁走）=====================
  //
  // 设置页的状态（分类选中、导入导出、B 站登录）已经整体迁到
  // `presentation/controller/settings_controller.dart`（ChangeNotifier），
  // 由 SettingsScope 挂在 App 根部，和 HomeController 完全解耦。
  // 这里不再持有任何设置页字段 —— 原来那几百行搬过去了，细节见那边。
}


/// 导航栏配置数据模型：带选中态图标
class NavigationItem {
  final IconData icon;
  final IconData activeIcon;
  final String title;

  const NavigationItem({required this.icon, required this.activeIcon, required this.title});
}
