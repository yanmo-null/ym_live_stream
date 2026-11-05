/// 兼容层：数据模型已迁移到 `lib/contract/live_models.dart`。
///
/// 保留这个文件是为了让存量代码继续 `import 'package:ym_live_stream/features/live_common.dart'`
/// 而不必一次性改几十处 import。
///
/// 【注意】这只导出数据契约，**不导出任何后端实现**。
/// 新代码请直接 import `lib/contract/live_models.dart`。
library;

export 'package:ym_live_stream/contract/live_models.dart';
