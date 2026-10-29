# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "ym_live_stream")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.example.ym_live_stream")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
#
# 【必须放在 include(generated_plugins.cmake) 之前，且必须无条件设置】
#
# flutter_js 的 linux/CMakeLists.txt 里有这么一段（上游代码，无法改）：
#   set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")      # 它自己的二进制目录
#   if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
#       set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" ... FORCE)
#   endif()
# 插件是被 add_subdirectory() 加进来的，一旦这段在 include 时先执行，就会把
# CMAKE_INSTALL_PREFIX 改成
#   build/linux/x64/debug/plugins/flutter_js/bundle
# 而且它用的是 FORCE + CACHE，污染会写进 CMakeCache.txt 一直留着。
#
# 后果不是"某个 .so 放错地方"这么简单：根 CMakeLists 里那条
#   install(CODE "file(REMOVE_RECURSE ${BUILD_BUNDLE_DIR}/)")
# 删的是真正的 build/.../bundle，而所有 install(FILES ...) 却写进了
# plugins/flutter_js/bundle —— 于是构建"成功"了，但 bundle/ 目录根本不存在，
# 启动时报：
#   Unable to start executable "build/linux/x64/debug/bundle/ym_live_stream"
#
# 原来的写法是 `if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)`，只在
# 首次配置时为真。第二次配置（cache 里已有被污染的值）时这个判断为假，
# 于是错误前缀被永久保留 —— 这正是"有时好有时坏"的来源。
#
# 所以这里：先无条件 FORCE 成本工程的 bundle 目录，再清掉
# CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT，最后才 include 插件。
# 那个标志是 CMake 在跑本脚本之前就按"默认前缀"置 1 的，光改前缀清不掉它，
# 必须显式 unset，插件里的 if 才会为假、不再覆盖。
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
unset(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# ============================================================================
# flutter_js：把 libquickjs_c_bridge_plugin.so 补进真正的 bundle/lib
# ============================================================================
#
# 【谁依赖它】不是可执行文件的 DT_NEEDED，所以 `ldd ym_live_stream` 看不到。
# 它是 flutter_js 在**运行时**用 dart:ffi 打开的：
#   flutter_js/lib/quickjs/ffi.dart:128
#   DynamicLibrary.open(Platform.environment['LIBQUICKJSC_PATH']
#                       ?? 'libquickjs_c_bridge_plugin.so')
# 传的是裸文件名，交给 glibc 的搜索路径去解析。而 glibc 解析 dlopen 的
# 「调用方 RUNPATH」是 dlopen 的发起者 —— 这里是 libflutter_linux_gtk.so，
# 它的 RUNPATH 只有 $ORIGIN（即 bundle/lib）。所以这个 .so 必须落在
# bundle/lib 里，否则就是：
#   Failed to load dynamic library 'libquickjs_c_bridge_plugin.so'
#
# 【为什么它不会自己落进去】flutter_js/linux/CMakeLists.txt 有两处问题：
#
#   1. 变量名不匹配：它导出的是 `flutter_qjs_bundled_libraries`，而 Flutter
#      生成的 generated_plugins.cmake 读的是 `${flutter_js_bundled_libraries}`
#      （由插件目录名推出来），所以 PLUGIN_BUNDLED_LIBRARIES 是空的，
#      foreach 一条也拷不到。
#      另外它写的是 $<TARGET_FILE:libquickjs_c_bridge_plugin.so>，而那个
#      target 根本不存在，真被读到也会在生成阶段报错。
#
#   2. 安装目录算错：它自己用 install(FILES ... DESTINATION
#      ${CMAKE_INSTALL_PREFIX}/lib) 硬装，而前缀被它自己那段 FORCE 改成了
#      plugins/flutter_js/bundle（详见本文件上面 "Installation" 一节），
#      于是这个 .so 落到
#        build/linux/x64/debug/plugins/flutter_js/bundle/lib/...
#      而不是应用真正会去加载的 bundle/lib。
#
# 【前缀那处已在下面修掉】把 CMAKE_INSTALL_PREFIX 提前并无条件设成本工程的
# bundle 目录，插件那段 FORCE 就不会再生效。本段保留的原因：
#   上游靠的是 `$<TARGET_FILE:...>` 且变量名不匹配，PLUGIN_BUNDLED_LIBRARIES
#   始终为空，所以这条 .so 永远没人拷 —— 必须我们自己补一条。
#
# 【修法】在根 CMakeLists 里、确认过 INSTALL_BUNDLE_LIB_DIR 之后再补一条安装
# 规则。库是 flutter_js 源码树里预编译好的（linux/shared/），直接取源文件，
# 不依赖构建顺序，干净构建也能生效。
# 不用 $<TARGET_FILE:...>，因为那要求库是 CMake target（它是预编译产物）。
# ============================================================================
set(FLUTTER_JS_LIB_NAME "libquickjs_c_bridge_plugin.so")
file(GLOB FLUTTER_JS_LIB_CANDIDATES
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_js/linux/shared/${FLUTTER_JS_LIB_NAME}")

if(FLUTTER_JS_LIB_CANDIDATES)
  install(FILES ${FLUTTER_JS_LIB_CANDIDATES}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  message(STATUS "flutter_js: bundling ${FLUTTER_JS_LIB_NAME} -> ${INSTALL_BUNDLE_LIB_DIR}")
else()
  # 不致命：只有抖音弹幕签名要用 JS 引擎，其它功能照常。
  message(WARNING
    "flutter_js: 没找到 ${FLUTTER_JS_LIB_NAME}（应在 "
    "linux/flutter/ephemeral/.plugin_symlinks/flutter_js/linux/shared/）。"
    "抖音弹幕将不可用。先跑一次 `flutter pub get` 生成 .plugin_symlinks。")
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
