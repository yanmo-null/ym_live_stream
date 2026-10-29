#ifndef RUNNER_QUICKJS_PRELOAD_H_
#define RUNNER_QUICKJS_PRELOAD_H_

namespace quickjs_preload {

// 在任何插件（尤其是 media_kit → libmpv → libmujs）加载之前，先用
// RTLD_DEEPBIND 把 flutter_js 的 QuickJS 桥接库加载进来。
//
// 必须在 main() 的最开头调用，早于 my_application_new()。
// 详见 quickjs_preload.cc 顶部关于符号冲突的说明。
void EnsurePreloaded();

}  // namespace quickjs_preload

#endif  // RUNNER_QUICKJS_PRELOAD_H_
