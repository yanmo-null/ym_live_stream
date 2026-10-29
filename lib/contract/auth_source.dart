/// 平台登录（扫码授权）的契约。
library;

import 'live_models.dart';

/// 二维码轮询结果。
class QrPollResult {
  /// 平台返回的状态码，含义由各平台自己定义
  final int code;

  /// 是否为「二维码已扫描，等待确认」
  final bool isScanned;

  /// 是否为「已确认，登录完成」
  final bool isSuccess;

  /// 是否为「二维码已过期」
  final bool isExpired;

  /// 是否为「尚未扫码」
  final bool isPending;

  const QrPollResult({required this.code, this.isScanned = false, this.isSuccess = false, this.isExpired = false, this.isPending = false});
}

/// 登录成功后的凭证摘要。
///
/// 具体有哪些 cookie 键由各平台决定，UI 只关心「有没有登录成功」和「昵称/UID」。
class LoginResult {
  /// 登录用户的昵称（拿不到时为 null）
  final String? nickname;

  /// 登录用户的唯一 id / UID（拿不到时为 null）
  final String? userId;

  const LoginResult({this.nickname, this.userId});
}

/// 登录失败时抛出的异常，[message] 可直接展示给用户。
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// 一个平台的登录能力。
abstract class AuthSource {
  /// 这个实现负责哪个平台
  LIVE_SITE_E get site;

  /// 这个平台是否支持扫码登录
  bool get supported;

  /// 启动扫码登录流程。
  ///
  /// [onQrcodeReady] 拿到二维码内容（通常是一个 URL，交给 UI 渲染成二维码）。
  /// [onPollUpdate] 每次轮询到状态变化时调用，UI 据此更新提示文案。
  ///
  /// 成功返回 [LoginResult]；失败抛 [AuthException]。
  Future<LoginResult> login({required void Function(String qrContent) onQrcodeReady, void Function(QrPollResult result)? onPollUpdate});

  /// 中止正在进行的登录（用户关掉了弹窗）。
  /// 必须支持重复调用。
  void stop();

  /// 当前是否已登录（有有效凭证）。
  Future<bool> isLoggedIn();

  /// 已登录时的账号摘要；未登录返回 null。
  Future<LoginResult?> currentAccount();

  /// 退出登录，清除本地凭证。
  Future<void> logout();
}

/// 登录实现的注册表。
class AuthSourceRegistry {
  AuthSourceRegistry._();

  static final Map<LIVE_SITE_E, AuthSource> _sources = {};

  /// 注册一个平台的登录实现。重复注册会覆盖。
  static void register(AuthSource source) {
    _sources[source.site] = source;
  }

  /// 取某个平台的登录实现；没注册返回 null。
  static AuthSource? find(LIVE_SITE_E site) => _sources[site];

  /// 该平台是否支持登录（既要有实现，且实现自己说 supported）
  static bool supports(LIVE_SITE_E site) => _sources[site]?.supported ?? false;

  static int get registeredCount => _sources.length;

  /// 清空注册（测试用）
  static void clear() => _sources.clear();
}
