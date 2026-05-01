import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/router/route_names.dart';

class ShopComparisonPage extends StatelessWidget {
  const ShopComparisonPage({super.key});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0, scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => context.canPop() ? context.pop() : context.go(RouteNames.hub),
        ),
        title: Text(l.hubCompare,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        centerTitle: true,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: const Color(0xFFF0F0F0))),
      ),
      body: Center(child: Text(l.hubCompare,
          style: const TextStyle(color: Color(0xFF6B7280)))),
    );
  }
}
