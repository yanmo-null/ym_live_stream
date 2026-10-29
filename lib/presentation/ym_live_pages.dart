import 'package:get/get.dart';

import 'package:ym_live_stream/core/route_path.dart';

import 'package:ym_live_stream/features/live_common.dart';

import 'package:ym_live_stream/presentation/home_page.dart';
import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

import 'package:ym_live_stream/presentation/live_room_page.dart';
import 'package:ym_live_stream/presentation/controller/live_room_controller.dart';

class YMLivePages {
  YMLivePages._();

  static final home_routes = [
    GetPage(name: RoutePath.p_home, page: () => const HomePage(), binding: BindingsBuilder.put(() => HomeController())),
  ];

  static final live_routes = [
    GetPage(
      name: RoutePath.p_liveroom,
      page: () => const LiveStreamPage(),
      binding: BindingsBuilder.put(() => LiveStreamController(args: LiveRoomArgs.fromDynamic(Get.arguments))),
    ),

    GetPage(
      name: RoutePath.p_liveroom_deep,
      page: () => const LiveStreamPage(),
      binding: BindingsBuilder.put(() => LiveStreamController(args: LiveRoomArgs.fromParameters(Get.parameters))),
    ),
  ];

  /// GetMaterialApp.getPages 用这一个
  static final all_routes = [...home_routes, ...live_routes];
}
