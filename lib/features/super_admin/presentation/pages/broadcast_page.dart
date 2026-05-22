import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';

/// SA-5 — Messagerie broadcast super-admin.
/// Composer un message (titre + corps + type + ciblage) puis consulter
/// l'historique des envois. S'appuie sur les méthodes statiques de
/// [AppDatabase] (`sendBroadcast`, `getBroadcasts`, `getPlansLite`).
class BroadcastPage extends StatefulWidget {
  final String shopId;
  const BroadcastPage({super.key, this.shopId = ''});

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _shopCtrl = TextEditingController();

  String _type = 'info'; // info | warning | maintenance
  String _target = 'all'; // all | plan | shop
  String? _planValue;

  bool _sending = false;
  late Future<List<Map<String, dynamic>>> _history;
  Future<List<Map<String, dynamic>>>? _plans;

  @override
  void initState() {
    super.initState();
    _history = AppDatabase.getBroadcasts();
    _plans = AppDatabase.getPlansLite();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _shopCtrl.dispose();
    super.dispose();
  }

  void _refreshHistory() {
    setState(() => _history = AppDatabase.getBroadcasts());
  }

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      AppSnack.error(context, 'Titre et message sont requis.');
      return;
    }
    String? targetValue;
    if (_target == 'plan') {
      if (_planValue == null) {
        AppSnack.error(context, 'Sélectionnez un plan cible.');
        return;
      }
      targetValue = _planValue;
    } else if (_target == 'shop') {
      final s = _shopCtrl.text.trim();
      if (s.isEmpty) {
        AppSnack.error(context, 'Renseignez l\'identifiant de la boutique.');
        return;
      }
      targetValue = s;
    }

    setState(() => _sending = true);
    try {
      await AppDatabase.sendBroadcast(
        title: title,
        body: body,
        type: _type,
        targetType: _target,
        targetValue: targetValue,
      );
      if (!mounted) return;
      AppSnack.success(context, 'Message envoyé.');
      _titleCtrl.clear();
      _bodyCtrl.clear();
      _shopCtrl.clear();
      setState(() {
        _type = 'info';
        _target = 'all';
        _planValue = null;
      });
      _refreshHistory();
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec de l\'envoi : $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Messagerie',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildComposer(context),
          const SizedBox(height: 24),
          const Text('Historique des envois',
              style: AppTextStyles.subtitleBold),
          const SizedBox(height: 12),
          _buildHistory(context),
        ],
      ),
    );
  }

  // ─── Composer ─────────────────────────────────────────────────────────────

  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Nouveau message', style: AppTextStyles.subtitle),
          const SizedBox(height: 16),
          _label('Titre'),
          const SizedBox(height: 6),
          TextField(
            controller: _titleCtrl,
            style: AppTextStyles.input,
            decoration: _inputDeco(context, 'Ex : Maintenance prévue'),
          ),
          const SizedBox(height: 16),
          _label('Message'),
          const SizedBox(height: 6),
          TextField(
            controller: _bodyCtrl,
            style: AppTextStyles.input,
            minLines: 3,
            maxLines: 6,
            decoration: _inputDeco(context, 'Contenu du message…'),
          ),
          const SizedBox(height: 16),
          _label('Type'),
          const SizedBox(height: 6),
          _dropdown<String>(
            context: context,
            value: _type,
            items: const [
              DropdownMenuItem(value: 'info', child: Text('Info')),
              DropdownMenuItem(value: 'warning', child: Text('Avertissement')),
              DropdownMenuItem(
                  value: 'maintenance', child: Text('Maintenance')),
            ],
            onChanged: (v) => setState(() => _type = v ?? 'info'),
          ),
          const SizedBox(height: 16),
          _label('Cible'),
          const SizedBox(height: 6),
          _dropdown<String>(
            context: context,
            value: _target,
            items: const [
              DropdownMenuItem(
                  value: 'all', child: Text('Toutes les boutiques')),
              DropdownMenuItem(value: 'plan', child: Text('Par plan')),
              DropdownMenuItem(value: 'shop', child: Text('Par boutique')),
            ],
            onChanged: (v) => setState(() {
              _target = v ?? 'all';
              _planValue = null;
            }),
          ),
          if (_target == 'plan') ...[
            const SizedBox(height: 12),
            _buildPlanSelector(context),
          ],
          if (_target == 'shop') ...[
            const SizedBox(height: 12),
            TextField(
              controller: _shopCtrl,
              style: AppTextStyles.input,
              decoration: _inputDeco(context, 'Identifiant de la boutique'),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _sending ? null : _send,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(_sending ? 'Envoi…' : 'Envoyer',
                  style: AppTextStyles.label.copyWith(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanSelector(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _plans,
      builder: (ctx, snap) {
        final plans = snap.data ?? const [];
        return _dropdown<String?>(
          context: context,
          value: _planValue,
          hint: 'Sélectionner un plan',
          items: [
            for (final p in plans)
              DropdownMenuItem<String?>(
                value: (p['name'] ?? '').toString(),
                child: Text(
                  (p['label'] ?? p['name'] ?? '').toString(),
                ),
              ),
          ],
          onChanged: (v) => setState(() => _planValue = v),
        );
      },
    );
  }

  // ─── Historique ─────────────────────────────────────────────────────────────

  Widget _buildHistory(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _history,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('Aucun message envoyé.',
                  style: AppTextStyles.bodySecondary),
            ),
          );
        }
        return Column(
          children: [
            for (final m in items) _historyTile(context, m),
          ],
        );
      },
    );
  }

  Widget _historyTile(BuildContext context, Map<String, dynamic> m) {
    final theme = Theme.of(context);
    final type = (m['type'] ?? 'info').toString();
    final title = (m['title'] ?? '').toString();
    final targetLabel = _targetLabel(m);
    final date = _formatDate(m['sent_at']);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: AppTextStyles.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              _typeBadge(type),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.adjust_rounded,
                  size: 12, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(targetLabel,
                    style: AppTextStyles.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(date, style: AppTextStyles.micro),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeBadge(String type) {
    final color = _typeColor(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _typeLabel(type),
        style: AppTextStyles.micro.copyWith(
            color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  Color _typeColor(String type) {
    switch (type) {
      case 'warning':
        return AppColors.warning;
      case 'maintenance':
        return const Color(0xFF8B5CF6); // violet
      case 'info':
      default:
        return AppColors.info;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'warning':
        return 'Avertissement';
      case 'maintenance':
        return 'Maintenance';
      case 'info':
      default:
        return 'Info';
    }
  }

  String _targetLabel(Map<String, dynamic> m) {
    final t = (m['target_type'] ?? 'all').toString();
    final v = m['target_value']?.toString();
    switch (t) {
      case 'plan':
        return 'Plan : ${v ?? '—'}';
      case 'shop':
        return 'Boutique : ${v ?? '—'}';
      case 'all':
      default:
        return 'Toutes les boutiques';
    }
  }

  String _formatDate(dynamic raw) {
    final d = DateTime.tryParse(raw?.toString() ?? '');
    if (d == null) return '—';
    return DateFormat('dd/MM/yy HH:mm').format(d.toLocal());
  }

  Widget _label(String text) =>
      Text(text, style: AppTextStyles.caption);

  InputDecoration _inputDeco(BuildContext context, String hint) {
    final theme = Theme.of(context);
    return InputDecoration(
      hintText: hint,
      hintStyle: AppTextStyles.inputHint,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      filled: true,
      fillColor: AppColors.inputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: theme.semantic.borderSubtle),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: theme.semantic.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );
  }

  Widget _dropdown<T>({
    required BuildContext context,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    String? hint,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          hint: hint == null
              ? null
              : Text(hint, style: AppTextStyles.inputHint),
          style: AppTextStyles.input.copyWith(
              color: theme.colorScheme.onSurface),
          dropdownColor: theme.colorScheme.surface,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
