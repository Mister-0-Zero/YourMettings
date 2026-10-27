import 'package:flutter/material.dart';

class HomeNavigation extends ValueNotifier<int> {
  HomeNavigation() : super(0);
}

class HomeNavigationScope extends InheritedNotifier<HomeNavigation> {
  const HomeNavigationScope({
    super.key,
    required HomeNavigation controller,
    required super.child,
  }) : super(notifier: controller);
  static HomeNavigation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HomeNavigationScope>()
      ?.notifier;
}

void returnToHome(BuildContext context) {
  HomeNavigationScope.maybeOf(context)?.value = 0;
  Navigator.of(context).popUntil((route) => route.isFirst);
}
