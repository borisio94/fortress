import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';

/// Sheet super-admin : gestion des sauvegardes d'UNE boutique.
/// - Active/désactive la sauvegarde automatique quotidienne (RPC
///   set_shop_backup_enabled).
/// - Liste les snapshots (table shop_backups).
/// - Sauvegarde à la demande / télécharge / restaure via l'edge function
///   shop-backup.
class ShopBackupSheet extends StatefulWidget {
  final String shopId;
  final String shopName;
  final bool initialEnabled;
  const ShopBackupSheet({
    super.key,
    required this.shopId,
    required this.shopName,
    required this.initialEnabled,
  });

  @override
  State<ShopBackupSheet> createState() => _ShopBackupSheetState();
}

class _ShopBackupSheetState extends State<ShopBackupSheet> {
  late bool _enabled = widget.initialEnabled;
  bool _loading = true;
  bool _working = false;
  List<Map<String, dynamic>> _backups = const [];

  final _client = Supabase.instance.client;
  final _dateFmt = DateFormat('dd/MM/yyyy HH:mm');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await _client
          .from('shop_backups')
          .select('id, created_at, size_bytes, row_counts, status, is_auto')
          .eq('shop_id', widget.shopId)
          .order('created_at', ascending: false);
      _backups = List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Chargement échoué : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleEnabled(bool v) async {
    setState(() => _working = true);
    try {
      await _client.rpc('set_shop_backup_enabled',
          params: {'p_shop_id': widget.shopId, 'p_enabled': v});
      if (mounted) {
        setState(() => _enabled = v);
        AppSnack.success(context,
            v ? 'Sauvegarde automatique activée' : 'Sauvegarde automatique désactivée');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _snapshotNow() async {
    setState(() => _working = true);
    try {
      final res = await _client.functions.invoke('shop-backup',
          body: {'mode': 'snapshot', 'shop_id': widget.shopId});
      final data = res.data;
      final ok = res.status == 200 && (data is Map && data['ok'] == true);
      if (!mounted) return;
      if (ok) {
        AppSnack.success(context, 'Sauvegarde créée');
        await _load();
      } else {
        AppSnack.error(context, 'Échec : ${data is Map ? data['error'] : data}');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _download(String backupId) async {
    setState(() => _working = true);
    try {
      final res = await _client.functions.invoke('shop-backup',
          body: {'mode': 'download', 'backup_id': backupId});
      final data = res.data;
      final url = (data is Map) ? data['url'] as String? : null;
      if (!mounted) return;
      if (url != null) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } else {
        AppSnack.error(context, 'Lien indisponible : ${data is Map ? data['error'] : data}');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore(Map<String, dynamic> backup) async {
    final when = DateTime.tryParse(backup['created_at']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Theme.of(c).colorScheme.surface,
        title: const Text('Restaurer cette sauvegarde ?'),
        content: Text(
          'Toutes les données ACTUELLES de « ${widget.shopName} » '
          '(produits, commandes, clients, stock…) seront REMPLACÉES par '
          'la sauvegarde du ${when != null ? _dateFmt.format(when.toLocal()) : '—'}.\n\n'
          'Cette action est irréversible. Continuer ?',
          style: AppTextStyles.bodySmSecondary,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Restaurer'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _working = true);
    try {
      final res = await _client.functions.invoke('shop-backup',
          body: {'mode': 'restore', 'backup_id': backup['id']});
      final data = res.data;
      final done = res.status == 200 && (data is Map && data['ok'] == true);
      if (!mounted) return;
      if (done) {
        AppSnack.success(context, 'Données restaurées');
      } else {
        AppSnack.error(context, 'Échec : ${data is Map ? data['error'] : data}');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _fmtSize(dynamic bytes) {
    final b = (bytes as num?)?.toDouble() ?? 0;
    if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} Mo';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} Ko';
    return '${b.toStringAsFixed(0)} o';
  }

  int _totalRows(dynamic counts) {
    if (counts is! Map) return 0;
    var n = 0;
    for (final v in counts.values) {
      if (v is num) n += v.toInt();
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: AppColors.inputBorder,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Row(children: [
              Icon(Icons.backup_rounded, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Sauvegardes', style: AppTextStyles.subtitleBold),
                  Text(widget.shopName,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ]),
              ),
              if (_working)
                const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
          // Toggle auto
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sauvegarde automatique quotidienne',
                            style: AppTextStyles.bodyBold),
                        const SizedBox(height: 2),
                        Text(
                            _enabled
                                ? 'Cette boutique est sauvegardée chaque nuit.'
                                : 'Désactivée — aucune sauvegarde automatique.',
                            style: AppTextStyles.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppSwitch(
                    value: _enabled,
                    onChanged: _working ? null : _toggleEnabled,
                  ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _working ? null : _snapshotNow,
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Sauvegarder maintenant'),
              ),
            ),
          ),
          const Divider(height: 18),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _backups.isEmpty
                    ? Center(
                        child: Text('Aucune sauvegarde pour le moment',
                            style: AppTextStyles.bodySmSecondary))
                    : ListView.separated(
                        controller: scroll,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: _backups.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _tile(_backups[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> b) {
    final when = DateTime.tryParse(b['created_at']?.toString() ?? '');
    final isAuto = b['is_auto'] == true;
    final failed = b['status'] == 'failed';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: failed
                  ? AppColors.error.withValues(alpha: 0.4)
                  : AppColors.inputBorder)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(when != null ? _dateFmt.format(when.toLocal()) : '—',
                  style: AppTextStyles.bodyBold),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: (isAuto ? AppColors.info : AppColors.secondary)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5)),
                child: Text(isAuto ? 'Auto' : 'Manuel',
                    style: AppTextStyles.microBold.copyWith(
                        color: isAuto ? AppColors.info : AppColors.secondary)),
              ),
            ]),
            const SizedBox(height: 2),
            Text(
                failed
                    ? 'Échec de la sauvegarde'
                    : '${_totalRows(b['row_counts'])} lignes · ${_fmtSize(b['size_bytes'])}',
                style: AppTextStyles.caption.copyWith(
                    color: failed ? AppColors.error : null)),
          ]),
        ),
        if (!failed) ...[
          IconButton(
            tooltip: 'Télécharger',
            onPressed: _working ? null : () => _download(b['id'] as String),
            icon: const Icon(Icons.download_rounded, size: 20),
            color: AppColors.secondary,
          ),
          IconButton(
            tooltip: 'Restaurer',
            onPressed: _working ? null : () => _restore(b),
            icon: const Icon(Icons.restore_rounded, size: 20),
            color: AppColors.warning,
          ),
        ],
      ]),
    );
  }
}
