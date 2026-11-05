import 'dart:math';
import "package:http/http.dart" as http;

import 'package:ym_live_stream/core/utils/utils.dart';

/// 兼容旧调用点：UA 的唯一来源是 UtilTools.default_user_agent（会话级、进程内一致），
/// 不要再在这里写第二份硬编码 UA，否则改 UA 会漏改一半。
String get kDesktopUserAgent => UtilTools.default_user_agent;

/// 各平台的基础头，参考平台自己页面请求的形态；
/// referer 由调用方按房间号传进来（带 referer 的请求在平台看来才"正常"）。
Map<String, String> browser_headers({
  String? referer,
  bool navigation = true, // true=像地址栏导航(HTML)，false=像页面内 XHR
}) {
  return <String, String>{
    'User-Agent': kDesktopUserAgent,
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Accept-Encoding': 'gzip, deflate, br',
    if (navigation) 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8' else 'Accept': '*/*',
    'sec-fetch-site': navigation ? 'none' : 'same-origin',
    'sec-fetch-mode': navigation ? 'navigate' : 'cors',
    'sec-fetch-dest': navigation ? 'document' : 'empty',
    if (referer != null) 'referer': referer,
  };
}

/// 按 host 的随机节流：等间隔(固定 1s)本身就是机器特征，
/// 用 200~800ms 随机间隔既能降频又不可识别。
final Map<String, DateTime> _lastRequestAt = {};
final Random _random = Random();

/// 重试策略：总尝试次数、首次退避基数。
const int _kMaxAttempts = 3;
const int _kBackoffBaseMs = 300;

/// 单次请求的超时。之前只有 http_get_no_redirect 单独设了超时，
/// 其它几个没有，遇到服务器不响应时会一直挂着不报错。
const Duration _kRequestTimeout = Duration(seconds: 15);

Future<void> _throttle(Uri uri) async {
  const minGapMs = 200;
  const jitterMs = 600;
  final last = _lastRequestAt[uri.host];
  if (last != null) {
    final target = Duration(milliseconds: minGapMs + _random.nextInt(jitterMs));
    final elapsed = DateTime.now().difference(last);
    if (elapsed < target) await Future.delayed(target - elapsed);
  }
  _lastRequestAt[uri.host] = DateTime.now();
}

class HttpException implements Exception {
  final int statusCode;
  final String body;
  HttpException(this.statusCode, this.body);

  /// 4xx（除 429）是"请求本身不对"，重试没意义，直接放弃
  bool get isFatal => statusCode >= 400 && statusCode < 500 && statusCode != 429;

  @override
  String toString() => 'HttpException: $statusCode, body: $body';
}

/// 响应是否算成功：2xx 才算，302 不算（需要读 Location 的调用方自己判断）。
bool _isSuccess(http.Response response) => response.statusCode >= 200 && response.statusCode < 300;

/// 指数退避 + 抖动：300ms, 600ms, ...
Future<void> _backoff(int attempt) async {
  final backoffMs = _kBackoffBaseMs * (1 << (attempt - 1)) + _random.nextInt(200);
  await Future.delayed(Duration(milliseconds: backoffMs));
}

// ===================== 对外 API =====================
//
// 【为什么不再用 _sendWithRetry(() => ...) 这种回调包一层】
// 之前的写法是：
//   return _sendWithRetry(() => http.get(uri, headers: headers));
// 重试逻辑和"到底发的是什么请求"被拆到两处，读代码要来回跳。
// 现在每个函数自己写循环，看得见完整的"发请求 → 判成功 → 退避重试"，
// 代价是三个函数各有一段相似的循环 —— 这点重复比回调更值得。
//
// 共用的部分（节流、成功判定、退避间隔、超时）仍然抽成上面几个小函数，
// 重复的只是那个 for 循环骨架本身。

/// GET 一个地址，只要响应正文（最常见的用法）。
Future<String> http_get_url_content(String url, {Map<String, String>? headers}) async {
  // 复用 http_get_response：节流、重试、超时都在那边做，
  // 这里只把 Response 拆成 body，不要再自己调一次 _throttle（会重复节流、白等一轮）。
  final response = await http_get_response(url, headers: headers);
  return response.body;
}

Future<String> http_post_url_content(String url, {Map<String, String>? headers, String? body}) async {
  final uri = Uri.parse(url);
  await _throttle(uri);

  Object? lastError;
  for (int attempt = 1; attempt <= _kMaxAttempts; attempt++) {
    try {
      final response = await http.post(uri, headers: headers, body: body).timeout(_kRequestTimeout);
      if (_isSuccess(response)) return response.body;

      final err = HttpException(response.statusCode, response.body);
      if (err.isFatal) throw err; // 403/404 等不重试
      lastError = err;
    } catch (e) {
      if (e is HttpException && e.isFatal) rethrow;
      lastError = e;
    }
    if (attempt == _kMaxAttempts) break;
    await _backoff(attempt);
  }
  throw Exception('Request failed after $_kMaxAttempts attempts: $lastError');
}

/// GET 一个地址并返回完整 Response（调用方想读状态码/响应头时用）。
Future<http.Response> http_get_response(String url, {Map<String, String>? headers}) async {
  final uri = Uri.parse(url);
  await _throttle(uri);

  Object? lastError;
  for (int attempt = 1; attempt <= _kMaxAttempts; attempt++) {
    try {
      final response = await http.get(uri, headers: headers).timeout(_kRequestTimeout);
      if (_isSuccess(response)) return response;

      final err = HttpException(response.statusCode, response.body);
      if (err.isFatal) throw err;
      lastError = err;
    } catch (e) {
      if (e is HttpException && e.isFatal) rethrow;
      lastError = e;
    }
    if (attempt == _kMaxAttempts) break;
    await _backoff(attempt);
  }
  throw Exception('Request failed after $_kMaxAttempts attempts: $lastError');
}

/// 【不跟随重定向的 GET】用来读 3xx 响应头里的 Location。
///
/// 为什么需要单独一个函数：dart:io 的 HttpClient 默认 followRedirects = true，
/// 打开后 302 会被自动消化成最终地址，**Location 头就拿不到了**。
/// 抖音的短链（v.douyin.com/xxxx）正是靠 Location 一路跳转到真实直播间，
/// 所以这里必须自己建客户端并关掉自动重定向。
///
/// 【这里不做"成功才返回"的重试】302/301 对我们恰恰是正常结果，
/// 按 2xx 才算成功来判会把它当成失败反复重试。网络层异常（连不上、超时）
/// 仍然重试，因为那种情况下重试是有意义的。
Future<http.Response> http_get_no_redirect(String url, {Map<String, String>? headers}) async {
  final uri = Uri.parse(url);
  await _throttle(uri);

  Object? lastError;
  for (int attempt = 1; attempt <= _kMaxAttempts; attempt++) {
    http.Client? client;
    try {
      client = http.Client();
      final request = http.Request('GET', uri);
      if (headers != null) request.headers.addAll(headers);
      // http 包在 IO 平台上会把 Request.followRedirects 透传给 HttpClient
      request.followRedirects = false;
      final streamed = await client.send(request).timeout(_kRequestTimeout);
      // 先读完流再关客户端：fromStream 会把 body 全部读进内存，
      // 必须在 finally 里 close 之前完成，否则连接会被提前掐断。
      return await http.Response.fromStream(streamed);
    } catch (e) {
      lastError = e;
    } finally {
      // 无论成功失败都要关掉，否则连接会漏
      client?.close();
    }
    if (attempt == _kMaxAttempts) break;
    await _backoff(attempt);
  }
  throw Exception('Request failed after $_kMaxAttempts attempts: $lastError');
}
