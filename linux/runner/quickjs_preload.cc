// ============================================================================
// 修复 QuickJS 与 muJS 的符号冲突（Linux 抖音弹幕崩溃）
// ============================================================================
//
// 【症状】
// 进入抖音直播间，视频有声音，弹幕一直“连接中”，约 2 秒后整个进程 SIGSEGV 闪退。
// 没有 Dart 异常，也没有 Flutter 的错误框 —— 因为它是原生层崩溃。
//
// 【根因：两个 JS 引擎导出了同名符号】
//   flutter_js 自带 libquickjs_c_bridge_plugin.so（QuickJS，内部有 js_malloc）
//   media_kit → libmpv.so.2 → libmujs.so.0.1（muJS，也导出 js_malloc）
//
// libmpv 的 DT_NEEDED 里有 libmujs，一旦开始播放视频，mujs 就以 RTLD_GLOBAL
// 进入进程的全局符号表。之后 QuickJS 库被 dlopen 进来时，它内部对 js_malloc
// 的调用会被动态链接器解析到 **mujs 的实现**（符号插入 / symbol interposition）。
// mujs 的 js_malloc 签名和 QuickJS 的完全不同，于是 QuickJS 初始化上下文时
// 拿到的指针是垃圾值，最终跳转到野地址：
//
//   #0  0x00007fae2d106288 ???
//   #1  js_new_shape2 (libquickjs_c_bridge_plugin.so + 0x21cdd)
//   #2  js_new_shape  (libquickjs_c_bridge_plugin.so + 0x21e45)
//   #3  JS_NewObjectProtoClass
//   #5  JS_AddIntrinsicBasicObjects
//   #7  JS_NewContext
//   #8  jsNewContext
//
// 用 gdb 看 core 能直接看到 frame #1 的 js_malloc 来自 /lib64/libmujs.so.0.1，
// 而不是 libquickjs_c_bridge_plugin.so —— 这就是证据。
//
// 【为什么必须在这里修】
// 修复手段是给 dlopen 加 RTLD_DEEPBIND（让库内引用优先解析到自身）。
// 但 Dart 的 DynamicLibrary.open 只接受路径字符串，没法传 flag，
// 而 flutter_js 又是用它来加载的。所以只能在 C++ runner 里抢先一步：
// 用 DEEPBIND 把 QuickJS 库加载进来，之后 Dart 那句
//   DynamicLibrary.open('libquickjs_c_bridge_plugin.so')
// 会复用同一个已加载的 handle（dlopen 对同 SONAME 的库返回同一句柄），
// 于是走的就已经是 deepbind 过的实例了。
//
// 注意 DEEPBIND 只能“先下手为强”：必须早于 libmpv/mujs 被加载，
// 所以调用点放在 main() 第一行。
// ============================================================================

// RTLD_DEEPBIND 是 GNU 扩展，必须在任何头文件之前定义 _GNU_SOURCE。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "quickjs_preload.h"

#include <dlfcn.h>
#include <unistd.h>

#include <cstdarg>
#include <cstdio>
#include <string>

namespace quickjs_preload {
namespace {

// 与 flutter_js/lib/quickjs/ffi.dart 里硬编码的文件名保持一致。
constexpr const char* kLibName = "libquickjs_c_bridge_plugin.so";

// 沿 /proc/self/exe 找到可执行文件所在目录，再拼 lib/。
// Flutter 的 Linux bundle 布局固定是 <exe目录>/lib/*.so。
std::string BundleLibDir() {
  char exe_path[4096];
  const ssize_t len = ::readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
  if (len <= 0) {
    return {};
  }
  exe_path[len] = '\0';
  std::string path(exe_path);
  const size_t slash = path.find_last_of('/');
  if (slash == std::string::npos) {
    return {};
  }
  return path.substr(0, slash) + "/lib/";
}

void Log(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  std::fputs("[quickjs_preload] ", stderr);
  std::vfprintf(stderr, fmt, args);
  std::fputc('\n', stderr);
  va_end(args);
}

}  // namespace

void EnsurePreloaded() {
  const std::string lib_dir = BundleLibDir();
  if (lib_dir.empty()) {
    Log("无法定位可执行文件目录，跳过预加载");
    return;
  }

  const std::string abs_path = lib_dir + kLibName;

  // RTLD_DEEPBIND：库内部对自己的符号引用优先，不被已加载的 mujs 抢走。
  // RTLD_NOW  : 立刻解析所有符号，问题在启动阶段就暴露，而不是播到一半才崩。
  // 不用 RTLD_GLOBAL：QuickJS 的符号没必要污染全局表。
  void* handle = ::dlopen(abs_path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
  if (handle != nullptr) {
    Log("已预加载 %s（RTLD_DEEPBIND），避开 muJS 的 js_malloc 冲突", abs_path.c_str());
    return;
  }

  // 退回：不带 DEEPBIND 再试一次。这能救“没有 mujs 的系统”，
  // 但在装了 mujs 的机器上仍会在建上下文时崩，所以还要给出提示。
  const char* first_error = ::dlerror();
  Log("DEEPBIND 预加载失败: %s", first_error != nullptr ? first_error : "unknown");

  handle = ::dlopen(abs_path.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (handle != nullptr) {
    Log("已退回普通方式预加载 %s", abs_path.c_str());
    return;
  }

  // 彻底失败：不影响启动，抖音弹幕会在运行时报错，其它功能正常。
  Log("预加载 %s 失败，抖音弹幕将不可用: %s",
      abs_path.c_str(),
      ::dlerror() != nullptr ? ::dlerror() : "unknown");
}

}  // namespace quickjs_preload
