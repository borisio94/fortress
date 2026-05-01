import 'package:flutter/material.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../crm/domain/entities/client.dart';

// ═════════════════════════════════════════════════════════════════════════════
// RecipientPickerSheet — bottom-sheet permettant de choisir le destinataire
// d'un message WhatsApp avant l'envoi (catalogue, promo, etc.).
//
// 2 modes :
//   • Saisie libre   → l'opérateur tape un numéro (format E.164 toléré,
//                      `0XXX...`, `+237 ...`, etc. — normalisé via
//                      PhoneFormatter.toWame)
//   • Choix client   → liste des clients de la boutique avec téléphone
//                      renseigné, filtrable par nom/téléphone/ville
//
// Retourne via `pop` :
//   • `String` : le numéro normalisé pour wa.me (chiffres, indicatif inclus)
//   • `null`   : annulation utilisateur
// ═════════════════════════════════════════════════════════════════════════════

Future<String?> pickWhatsappRecipient(
  BuildContext context, {
  required String shopId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _RecipientPickerSheet(shopId: shopId),
  );
}

class _RecipientPickerSheet extends StatefulWidget {
  final String shopId;
  const _RecipientPickerSheet({required this.shopId});

  @override
  State<_RecipientPickerSheet> createState() => _RecipientPickerSheetState();
}

class _RecipientPickerSheetState extends State<_RecipientPickerSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _phoneCtrl  = TextEditingController();
  final _searchCtrl = TextEditingController();

  List<Client> _clients = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadClients();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim();
      if (q != _query) setState(() => _query = q);
    });
    _phoneCtrl.addListener(() => setState(() {}));
  }

  void _loadClients() {
    final all = AppDatabase.getClientsForShop(widget.shopId);
    // On ne garde que les clients avec un téléphone exploitable.
    setState(() {
      _clients = all
          .where((c) => (c.phone ?? '').trim().isNotEmpty)
          .toList()
        ..sort((a, b) => a.name.toLowerCase()
            .compareTo(b.name.toLowerCase()));
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _phoneCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll('à', 'a').replaceAll('â', 'a').replaceAll('ä', 'a')
      .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ê', 'e').replaceAll('ë', 'e')
      .replaceAll('î', 'i').replaceAll('ï', 'i')
      .replaceAll('ô', 'o').replaceAll('ö', 'o')
      .replaceAll('ù', 'u').replaceAll('û', 'u').replaceAll('ü', 'u')
      .replaceAll('ç', 'c');

  List<Client> get _filtered {
    if (_query.isEmpty) return _clients;
    final q = _normalize(_query);
    return _clients.where((c) {
      final hay = _normalize([
        c.name, c.phone ?? '', c.city ?? '', c.email ?? '',
      ].join(' '));
      return hay.contains(q);
    }).toList();
  }

  void _confirmPhone(String phone) {
    final wame = PhoneFormatter.toWame(phone);
    if (wame.isEmpty) return;
    Navigator.of(context).pop(wame);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: maxH,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              _header(),
              const Divider(height: 1, color: AppColors.divider),
              TabBar(
                controller: _tabs,
                labelColor: AppColors.primary,
                unselectedLabelColor: AppColors.textHint,
                indicatorColor: AppColors.primary,
                indicatorWeight: 2,
                labelStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700),
                tabs: const [
                  Tab(text: 'Choisir un client'),
                  Tab(text: 'Saisir un numéro'),
                ],
              ),
              const Divider(height: 1, color: AppColors.divider),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _clientList(),
                    _phoneInput(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
    child: Column(
      children: [
        Center(
          child: Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF25D366).withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.send_rounded,
                size: 18, color: Color(0xFF25D366)),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Destinataire WhatsApp',
                style: TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            color: AppColors.textHint,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ]),
      ],
    ),
  );

  // ── Onglet 1 : liste clients ────────────────────────────────────────────

  Widget _clientList() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: SizedBox(
          height: 38,
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Rechercher (nom, téléphone, ville…)',
              hintStyle: const TextStyle(fontSize: 12,
                  color: AppColors.textHint),
              prefixIcon: const Icon(Icons.search_rounded,
                  size: 16, color: AppColors.textHint),
              suffixIcon: _query.isEmpty ? null : IconButton(
                icon: const Icon(Icons.close_rounded,
                    size: 14, color: AppColors.textHint),
                splashRadius: 16,
                onPressed: () => _searchCtrl.clear(),
              ),
              contentPadding: EdgeInsets.zero,
              filled: true, fillColor: AppColors.inputFill,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.divider)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.primary)),
            ),
          ),
        ),
      ),
      Expanded(
        child: _clients.isEmpty
            ? const _Empty(
                icon: Icons.people_outline_rounded,
                title: 'Aucun client avec téléphone',
                subtitle: 'Ajoute le numéro WhatsApp dans la fiche '
                    'd\'un client pour le voir ici.',
              )
            : _filtered.isEmpty
                ? const _Empty(
                    icon: Icons.search_off_rounded,
                    title: 'Aucun résultat',
                    subtitle: 'Essaie avec un autre mot-clé.',
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: AppColors.divider),
                    itemBuilder: (_, i) {
                      final c = _filtered[i];
                      return _clientTile(c);
                    },
                  ),
      ),
    ]);
  }

  Widget _clientTile(Client c) => InkWell(
    onTap: () => _confirmPhone(c.phone!),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.primary.withOpacity(0.12),
          child: Text(
            c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
            style: TextStyle(fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(c.phone ?? '',
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textSecondary)),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded,
            size: 18, color: AppColors.textHint),
      ]),
    ),
  );

  // ── Onglet 2 : saisie numéro libre ──────────────────────────────────────

  Widget _phoneInput() {
    final raw = _phoneCtrl.text.trim();
    final preview = raw.isEmpty ? null : PhoneFormatter.toWame(raw);
    final canSend = preview != null && preview.length >= 8;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Numéro WhatsApp du destinataire',
              style: TextStyle(fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            autofocus: true,
            style: const TextStyle(fontSize: 14,
                fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: '+237 6XX XX XX XX',
              hintStyle: const TextStyle(fontSize: 13,
                  color: AppColors.textHint),
              prefixIcon: const Icon(Icons.phone_outlined,
                  size: 18, color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.inputFill,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.divider)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
            ),
          ),
          if (preview != null && preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Sera envoyé à : +$preview',
                style: const TextStyle(fontSize: 11,
                    color: AppColors.textHint,
                    fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 16),
          Text('Indicatif pays automatique : si tu tapes `0XXX...` '
              'ou un numéro local commençant par 6 ou 2, l\'indicatif '
              '+237 (Cameroun) est ajouté.',
              style: TextStyle(fontSize: 10,
                  color: AppColors.textHint)),
          const Spacer(),
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              onPressed: canSend ? () => _confirmPhone(raw) : null,
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Envoyer à ce numéro',
                  style: TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  const _Empty({
    required this.icon, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: AppColors.divider),
          const SizedBox(height: 10),
          Text(title,
              style: const TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(subtitle, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11,
                  color: AppColors.textHint)),
        ],
      ),
    ),
  );
}
