#include "my_application.h"

#include "quickjs_preload.h"

int main(int argc, char** argv) {
  // 【必须第一行】先于 my_application_new()（它会注册插件、拉起 media_kit/mpv）。
  // 详见 quickjs_preload.cc 里关于 QuickJS 与 muJS 符号冲突的说明。
  quickjs_preload::EnsurePreloaded();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
