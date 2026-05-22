import 'package:flutter/material.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
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
        Text(l.crmMessage, style: AppTextStyles.bodySmSecondary),
        const SizedBox(height: 5),
        TextFormField(maxLines: 4,
            decoration: InputDecoration(hintText: l.crmMessageHint,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                isDense: true,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: Theme.of(context).semantic.borderSubtle)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: Theme.of(context).semantic.borderSubtle)),
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
