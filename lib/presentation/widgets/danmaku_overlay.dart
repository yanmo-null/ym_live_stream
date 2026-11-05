import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:ym_live_stream/features/danmaku_message.dart';

/// 视频画面上方的**横向滚动**弹幕层（从右往左飞）。
///
/// 设计要点（性能优先，对齐 pure_live 的"游戏循环 + 预光栅化"思路）：
///
///   * **绝不在每帧 setState 重建整棵树**。旧实现每条弹幕都是一个 [Text]，
///     靠单个 Ticker 每帧 `setState((){})` 全量重建 —— N 条弹幕每帧都要重跑
///     build / layout / rasterize（带描边的 CJK 文字光栅化极贵），主线程直接
///     被压垮，开启滚动弹幕后画面就卡。
///   * 现在只用一个 Ticker 当时钟，把累计时间写进一个 [ValueNotifier]。
///     每条弹幕是独立的 [_FlyingDanmaku]，它用 [ValueListenableBuilder]
///     只重建**自己**的 [Transform] 位移；文字部分包在 [RepaintBoundary] 里，
///     位移只走到合成层（GPU 平移），**不会重新排版/光栅化文字**。
///   * 父层（[_DanmakuOverlayState]）只在"发射新弹幕 / 移除飞出弹幕"这种
///     **结构性变化**时 setState，频率很低（每秒几次），不再是每帧 60 次。
///   * 弹幕飞出左边界后从活跃列表里移除，内存长期稳定。
///
/// 不显示昵称（按需求：弹幕只滚动正文）。
class DanmakuOverlay extends StatefulWidget {
  /// 要展示的弹幕（按时间顺序，最新的在末尾）。
  ///
  /// 注意：这个列表是「整个房间的弹幕池」，不是「当前该飞的弹幕」。
  /// 组件自己记录「已经发射到第几条」，只把新增的那些加入飞行队列。
  final List<DanmakuMessage> messages;

  /// 字号（逻辑像素）
  final double fontSize;

  /// 同屏同时飞行的上限
  final int maxOnScreen;

  /// 一条弹幕从右侧进入到完全飞出左侧的时长。
  ///
  /// 太长会积压（同屏很快达到上限），太短看不清。
  /// 由 controller 的「滚动速度」设置控制，越大越慢。
  final Duration flightDuration;

  const DanmakuOverlay({
    super.key,
    required this.messages,
    required this.fontSize,
    required this.maxOnScreen,
    this.flightDuration = const Duration(seconds: 12),
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

/// 一条正在飞行的弹幕（纯数据，位置由 elapsed 解析算出）。
class _FlyingItem {
  _FlyingItem({required this.id, required this.text, required this.lane, required this.startedAt, required this.width});

  /// 稳定唯一 id：用于给 [_FlyingDanmaku] 当 key，避免复用错位。
  final int id;

  final String text;

  /// 所在轨道序号（决定纵向位置）
  final int lane;

  /// 开始飞行的时刻（全局时钟）
  final Duration startedAt;

  /// 估算的文本宽度（用于判断能否并排）
  final double width;
}

class _DanmakuOverlayState extends State<DanmakuOverlay> with SingleTickerProviderStateMixin {
  /// 全局时钟：单个 Ticker 驱动，把它写进这个 notifier，
  /// 各弹幕项各自监听、各自只重建自己的位移。父层不参与每帧重建。
  late final Ticker _ticker;
  final ValueNotifier<Duration> _clock = ValueNotifier<Duration>(Duration.zero);

  /// 正在飞行的弹幕
  final List<_FlyingItem> _flying = [];

  /// 自增 id，保证每条弹幕 widget 的 key 唯一稳定
  int _nextId = 0;

  /// 轨道数（按区域高度和行高算，随布局变化更新）
  int _laneCount = 1;

  /// 组件可用宽度（测车道要用）
  double _viewWidth = 0;

  /// 每帧最多发射几条：防止切换 / 卡顿后一次性涌入几十条弹幕糊满屏幕
  static const int _kMaxBurstPerFrame = 8;

  /// 最后一条已发射弹幕的标识（receivedAt + content）
  ///
  /// 【不能用下标】池子上限 200 条，满了以后长度不再增长，
  /// 但内容一直在“旧的裁掉、新的加进来”。若用 `_consumed < pool.length`
  /// 判断，池子满的那一刻就永远不再发射新弹幕了 ——
  /// 表现就是「看着看着弹幕全没了」。
  /// 所以改成记录**最后一条已发射弹幕的特征**，每帧在池子里找它之后的新内容。
  String? _lastEmittedKey;

  /// 上次执行「移除 / 发射」判定时的时钟时刻。
  ///
  /// 父层的结构性刷新不用每帧都做：每帧都 setState 又回到了老问题。
  /// 这里用一个很短的节流窗口（约 60ms，约 16fps 做一次 bookkeeping），
  /// 足够及时地发射和清理，同时把父层 setState 次数从 60/s 降到 ~16/s。
  Duration _lastBookkeepAt = Duration.zero;
  static const Duration _kBookkeepInterval = Duration(milliseconds: 60);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  /// 一条弹幕的唯一标识（同一毫秒内文案相同也算同一条）
  static String _keyOf(DanmakuMessage m) => '${m.receivedAt.microsecondsSinceEpoch}|${m.content}';

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 换房间：池子被清空（或换成了完全不同的内容）时，忘掉上一条，
    // 否则新房间的弹幕会一直被判定成“已经发过了”。
    // didUpdateWidget 之后框架一定会 build，这里直接改状态即可，不用 setState。
    if (widget.messages.isEmpty) {
      _lastEmittedKey = null;
      _flying.clear();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    // 1) 每帧只做一件"轻"事：更新时钟，驱动各弹幕项自己的位移动画。
    //    这一步不会触发父层 build，也不会重新光栅化文字。
    _clock.value = elapsed;

    // 2) 结构性 bookkeeping（发射 / 移除）做成低频节流，
    //    避免每帧 setState。
    if (elapsed - _lastBookkeepAt < _kBookkeepInterval) return;
    _lastBookkeepAt = elapsed;

    final flightMs = widget.flightDuration.inMilliseconds;
    final removedAny = _flying.any((item) => (elapsed - item.startedAt).inMilliseconds > flightMs);

    var emittedAny = false;
    // 先清掉飞出的，再尝试发射新的（清掉后腾出同屏名额）
    if (removedAny || _flying.isEmpty) {
      // 用微秒比较，和进度计算精度一致
      _flying.removeWhere((item) => (elapsed - item.startedAt).inMicroseconds > flightMs * 1000);
    }
    if (_viewWidth > 0) {
      emittedAny = _pumpNewMessages(elapsed);
    }

    // 只有真的发生变化才 setState（低频）
    if (removedAny || emittedAny) {
      if (mounted) setState(() {});
    }
  }

  /// 尝试把池子里**还没发射过**的弹幕发出去。返回是否有发射。
  bool _pumpNewMessages(Duration now) {
    final pool = widget.messages;
    if (pool.isEmpty) return false;

    // 找到「上次发射的那条」在池子里的位置。
    var start = 0;
    final lastKey = _lastEmittedKey;
    if (lastKey != null) {
      for (var i = pool.length - 1; i >= 0; i--) {
        if (_keyOf(pool[i]) == lastKey) {
          start = i + 1;
          break;
        }
      }
    }

    var emitted = 0;
    for (var i = start; i < pool.length; i++) {
      if (emitted >= _kMaxBurstPerFrame) break;

      // 达到同屏上限就停：剩下的留在池子里，等有位置了下一帧再发。
      if (_flying.length >= widget.maxOnScreen) break;

      final msg = pool[i];

      // 先算宽度：选轨道要用它判断「这条放得下吗」
      final textWidth = _estimateWidth(msg.content);
      final lane = _pickLane(textWidth, now);
      if (lane < 0) break; // 所有轨道都还没让开，等下一次 bookkeeping

      _flying.add(_FlyingItem(id: _nextId++, text: msg.content, lane: lane, startedAt: now, width: textWidth));
      _lastEmittedKey = _keyOf(msg);
      emitted++;
    }
    return emitted > 0;
  }

  /// 选一条可以放新弹幕的轨道；没有返回 -1。
  int _pickLane(double newWidth, Duration now) {
    final flightUs = widget.flightDuration.inMicroseconds;

    for (var lane = 0; lane < _laneCount; lane++) {
      double rightmostEdge = double.negativeInfinity;
      for (final item in _flying) {
        if (item.lane != lane) continue;
        if (flightUs <= 0) return lane;

        final progress = ((now - item.startedAt).inMicroseconds / flightUs).clamp(0.0, 1.0);
        // 飞行起点：左边缘在 _viewWidth（完全在屏幕右侧之外）
        final leftX = _viewWidth - progress * (_viewWidth + item.width);
        final edge = leftX + item.width; // 右边缘
        if (edge > rightmostEdge) rightmostEdge = edge;
      }

      if (rightmostEdge == double.negativeInfinity) return lane;

      final requiredGap = newWidth + widget.fontSize;
      if (rightmostEdge < _viewWidth - requiredGap) return lane;
    }
    return -1;
  }

  /// 粗略估算文本宽度：中文字符按 1 个字宽，ASCII 按 0.55。
  double _estimateWidth(String text) {
    var width = 0.0;
    for (final rune in text.runes) {
      width += rune <= 0x7F ? widget.fontSize * 0.55 : widget.fontSize;
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final newWidth = constraints.maxWidth;

        // 行高：字号 * 1.5，留出上下间隔
        final lineHeight = widget.fontSize * 1.5;
        final areaHeight = constraints.maxHeight;
        final newLaneCount = math.max(1, (areaHeight / lineHeight).floor());

        // 区域尺寸变化（全屏/改显示范围）时更新轨道数与宽度。
        // 越界的 lane 压回有效范围，飞行进度保持不变。
        if (newLaneCount != _laneCount || newWidth != _viewWidth) {
          if (_flying.isNotEmpty) {
            final maxLane = newLaneCount - 1;
            for (var i = 0; i < _flying.length; i++) {
              final item = _flying[i];
              if (item.lane > maxLane) {
                _flying[i] = _FlyingItem(id: item.id, text: item.text, lane: item.lane % newLaneCount, startedAt: item.startedAt, width: item.width);
              }
            }
          }
          _viewWidth = newWidth;
          _laneCount = newLaneCount;
        }

        return ClipRect(
          child: Stack(
            children: [
              for (final item in _flying)
                // Positioned 由父层（Stack 的直接子节点）包裹，
                // 保证 RenderStack 能拿到定位 parentData，不会踩 ParentDataWidget 的坑。
                Positioned(
                  key: ValueKey<int>(item.id),
                  top: item.lane * lineHeight,
                  left: 0,
                  right: 0,
                  height: lineHeight,
                  child: _FlyingDanmaku(clip: item, clock: _clock, viewWidth: _viewWidth, flightDuration: widget.flightDuration, fontSize: widget.fontSize),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 单条飞行的弹幕（内容层，定位由父层的 Positioned 负责）。
///
/// 只监听共享时钟 [clock]，用 [ValueListenableBuilder] 重建自己的 [Transform]
/// 位移。文字内容包在 [RepaintBoundary] 里 —— 位移变化只让合成层平移这块
/// 已光栅化的位图，不会重新排版/绘制文字，这是"不卡"的关键。
class _FlyingDanmaku extends StatelessWidget {
  const _FlyingDanmaku({required this.clip, required this.clock, required this.viewWidth, required this.flightDuration, required this.fontSize});

  final _FlyingItem clip;
  final ValueListenable<Duration> clock;
  final double viewWidth;
  final Duration flightDuration;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final flightUs = flightDuration.inMicroseconds;

    return Align(
      alignment: Alignment.centerLeft,
      child: ValueListenableBuilder<Duration>(
        valueListenable: clock,
        builder: (context, now, child) {
          final progress = flightUs <= 0 ? 1.0 : ((now - clip.startedAt).inMicroseconds / flightUs).clamp(0.0, 1.0);
          // 起点左边缘 = viewWidth（屏幕右外）；终点左边缘 = -width（左外）
          final x = viewWidth - progress * (viewWidth + clip.width);
          return Transform.translate(offset: Offset(x, 0), child: child);
        },
        // child 只构建一次：文字 + 文字描边，后续每帧只重用这块已构建/已光栅化的子树
        child: RepaintBoundary(child: _buildText()),
      ),
    );
  }

  Widget _buildText() {
    return Text(
      clip.text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: TextStyle(
        color: Colors.white,
        fontSize: fontSize,
        height: 1.2,
        fontWeight: FontWeight.w600,
        // 【看清弹幕】直播画面明暗不定，单靠一层柔和阴影在亮背景上会糊。
        // 用多方向描边（四面各一个 1px 黑影）+ 一层下垂模糊阴影：
        //   * 四向描边给白字一圈实边，任何背景都能"抠"出来；
        //   * 模糊阴影补足边角过渡，避免描边显得太硬。
        shadows: [
          Shadow(color: Colors.black.withValues(alpha: 0.9), blurRadius: 2, offset: const Offset(-1, 0)),
          Shadow(color: Colors.black.withValues(alpha: 0.9), blurRadius: 2, offset: const Offset(1, 0)),
          Shadow(color: Colors.black.withValues(alpha: 0.9), blurRadius: 2, offset: const Offset(0, -1)),
          Shadow(color: Colors.black.withValues(alpha: 0.9), blurRadius: 2, offset: const Offset(0, 1)),
          Shadow(color: Colors.black.withValues(alpha: 0.7), blurRadius: 4, offset: const Offset(1, 1)),
        ],
      ),
    );
  }
}
