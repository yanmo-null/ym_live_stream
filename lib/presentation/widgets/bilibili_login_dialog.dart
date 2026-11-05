import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:ym_live_stream/contract/auth_source.dart';
import 'package:ym_live_stream/contract/live_models.dart';

/// 扫码登录弹窗（通用，不限于某个平台）。
///
/// 拿到二维码内容后用 QrImageView 渲染，用户扫码授权后自动关窗。
///
/// 【为什么叫 Bilibili 但代码是通用的】目前只有 B 站支持扫码登录；
/// 以后接入别的平台，直接传不同的 [site] 即可，不用再写一个弹窗。
class BilibiliLoginDialog extends StatefulWidget {
  /// 要登录的平台
  final LIVE_SITE_E site;

  const BilibiliLoginDialog({super.key, this.site = LIVE_SITE_E.LIVE_SITE_BILIBILI});

  @override
  State<BilibiliLoginDialog> createState() => _BilibiliLoginDialogState();
}

class _BilibiliLoginDialogState extends State<BilibiliLoginDialog> {
  /// 登录实现（从注册表取，UI 不认识具体类）
  late final AuthSource? _auth;

  /// 二维码内容（拿到后显示给用户）
  String? _qrUrl;

  /// 轮询状态文案
  String _status = '正在获取登录二维码…';

  /// 是否已经结束（成功/失败），结束就不再更新状态
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _auth = AuthSourceRegistry.find(widget.site);
    // 首帧之后再启动，保证 dialog 已经挂载，出错时才能安全地 setState / 关窗
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLogin());
  }

  @override
  void dispose() {
    // 页面销毁时通知服务停止轮询，避免后台一直跑
    _auth?.stop();
    super.dispose();
  }

  /// 关闭弹窗并把结果回传给 `showDialog` 的调用方。
  ///
  /// 【从 Get.back 换成 Navigator.pop】路由已迁到 go_router，GetX 不再持有
  /// Navigator，`Get.back()` 在这个 dialog 里会静默失败（窗口关不掉）。
  /// 用 `Navigator.of(context).pop(result)` 才是 showDialog 的正确关闭方式。
  void _closeWith(Object? result) {
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _startLogin() async {
    final auth = _auth;
    if (auth == null) {
      // 这个平台没注册登录实现（比如开源版没接后端）：
      // 直接提示并关窗，不要让用户对着一个永远转圈的二维码等。
      if (!mounted) return;
      _finished = true;
      _closeWith('当前版本未启用登录功能');
      return;
    }

    try {
      final result = await auth.login(
        onQrcodeReady: (url) {
          if (!mounted) return;
          setState(() {
            _qrUrl = url;
            _status = '请使用手机 App 扫码登录';
          });
        },
        onPollUpdate: (r) {
          if (!mounted || _finished) return;
          if (r.isScanned) {
            setState(() => _status = '已扫码，请在手机上确认');
          } else if (r.isPending) {
            setState(() => _status = '等待扫码…');
          }
        },
      );

      if (!mounted) return;
      _finished = true;
      // 登录成功：关窗 + 把结果回传给调用方（snackbar 由调用方弹）
      _closeWith(result);
    } on AuthException catch (e) {
      if (!mounted) return;
      _finished = true;
      _closeWith(e.message);
    } catch (e) {
      if (!mounted) return;
      _finished = true;
      _closeWith('登录失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 340,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('哔哩哔哩登录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF222222))),
            const SizedBox(height: 14),

            // 二维码区域：拿到 url 后渲染真实二维码。
            // 扫码内容就是 B 站返回的 data.url（account.bilibili.com 的 scan-web 地址），
            // 手机 App 扫它才会走完整的授权回跳流程。
            Center(
              child: Container(
                width: 180,
                height: 180,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE0E0E0)),
                ),
                child: _qrUrl == null
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : QrImageView(
                        data: _qrUrl!,
                        version: QrVersions.auto,
                        // 背景必须是白的，二维码靠对比度扫描；透明底扫不出来
                        backgroundColor: Colors.white,
                        // 二维码内部留白交给外层 padding 控制，这里设 0
                        padding: EdgeInsets.zero,
                        // 容错等级 M：允许二维码有一定遮挡/模糊仍可识别
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
              ),
            ),
            const SizedBox(height: 12),

            // 状态文案
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),

            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                // 取消 = 停止轮询并关窗，回到 result 为 null 的分支
                onPressed: () => _closeWith(null),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF888888)),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
