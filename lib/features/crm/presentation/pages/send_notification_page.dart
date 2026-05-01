import 'package:flutter/material.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';

class SendNotificationPage extends StatelessWidget {
  final String shopId;
  const SendNotificationPage({super.key, required this.shopId});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppScaffold(
      shopId: shopId, title: l.crmSendNotif, isRootPage: false,
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(l.crmMessage, style: const TextStyle(fontSize: 12,
            fontWeight: FontWeight.w500, color: Color(0xFF6B7280))),
        const SizedBox(height: 5),
        TextFormField(maxLines: 4,
            decoration: InputDecoration(hintText: l.crmMessageHint,
                filled: true, fillColor: Colors.white, isDense: true,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.primary, width: 1.5)))),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, height: 43,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.send_rounded, color: Colors.white, size: 16),
            label: Text(l.crmSend, style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
            onPressed: () {},
          ),
        ),
      ]),
    );
  }
}
