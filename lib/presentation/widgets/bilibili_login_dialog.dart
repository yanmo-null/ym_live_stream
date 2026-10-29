import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:ym_live_stream/contract/auth_source.dart';
import 'package:ym_live_stream/contract/live_models.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLogin());
  }

  @override
  void dispose() {
    _auth?.stop();
    super.dispose();
  }

  Future<void> _startLogin() async {
    final auth = _auth;
    if (auth == null) {
      if (!mounted) return;
      _finished = true;
      Get.back(result: '当前版本未启用登录功能');
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
      Get.back(result: result);
    } on AuthException catch (e) {
      if (!mounted) return;
      _finished = true;
      Get.back(result: e.message);
    } catch (e) {
      if (!mounted) return;
      _finished = true;
      Get.back(result: '登录失败：$e');
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
                        backgroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
              ),
            ),
            const SizedBox(height: 12),

            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),

            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Get.back(),
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
