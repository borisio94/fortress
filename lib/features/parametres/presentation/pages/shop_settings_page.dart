import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../core/widgets/owner_pin_dialog.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../features/auth/domain/entities/user.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';
import '../../../hr/presentation/pages/employees_page.dart';

/// Onglets exposés. `overview` (Boutique) est conditionnel : visible
/// uniquement quand `showOverviewTab == true` (entrée via le tile
/// « Paramètres boutique » de la page Paramètres). L'entrée drawer admin
/// « Gestion boutique » garde la version sans onglet Boutique pour éviter
/// le doublon avec les sections de la page Paramètres.
///
/// Onglet `danger` retiré : les actions destructives sont maintenant
/// regroupées dans la zone dangereuse de la page Paramètres principale
/// (cf. `_DangerSection` dans parametres_page.dart). La valeur reste
/// dans l'enum pour rétro-compatibilité (mappée sur Membres).
enum ShopSettingsTab { overview, members, copy, danger }

class ShopSettingsPage extends ConsumerStatefulWidget {
  final String shopId;
  final ShopSettingsTab initialTab;
  /// Si `true`, l'onglet « Boutique » (overview) est inséré comme premier
  /// onglet. Activé via le query param `?with_overview=1` quand la page
  /// est ouverte depuis Paramètres → Paramètres boutique.
  final bool showOverviewTab;
  const ShopSettingsPage({
    super.key,
    required this.shopId,
    this.initialTab = ShopSettingsTab.members,
    this.showOverviewTab = false,
  });
  @override
  ConsumerState<ShopSettingsPage> createState() => _ShopSettingsPageState();
}

class _ShopSettingsPageState extends ConsumerState<ShopSettingsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  bool _loadingMembers = false;
  List<Map<String, dynamic>> _members = [];

  static const _baseTabs = [
    (icon: Icons.people_alt_rounded,       label: 'Membres'),
    (icon: Icons.content_copy_rounded,     label: 'Copier'),
  ];

  static const _overviewTabDef =
      (icon: Icons.storefront_rounded, label: 'Boutique');

  List<({IconData icon, String label})> get _tabs => widget.showOverviewTab
      ? const [_overviewTabDef, ..._baseTabs]
      : _baseTabs;

  /// Mapping enum → index de tab. L'offset dépend de la présence de
  /// l'onglet Boutique (overview) en première position. `danger` est
  /// historique (onglet retiré) — mappé sur Membres pour rétro-compat.
  int _initialIndexFor(ShopSettingsTab t) {
    if (widget.showOverviewTab) {
      return switch (t) {
        ShopSettingsTab.overview => 0,
        ShopSettingsTab.members || ShopSettingsTab.danger => 1,
        ShopSettingsTab.copy     => 2,
      };
    }
    return switch (t) {
      ShopSettingsTab.overview
          || ShopSettingsTab.members
          || ShopSettingsTab.danger => 0,
      ShopSettingsTab.copy   => 1,
    };
  }

  /// Index de l'onglet « Membres » selon le mode d'affichage.
  int get _membersIndex => widget.showOverviewTab ? 1 : 0;

  /// Index de l'onglet « Copier » (toujours le dernier).
  int get _copyIndex => _tabs.length - 1;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: _initialIndexFor(widget.initialTab),
    );
    // Sync URL ↔ tab : sans ce listener, switcher de tab via la TabBar
    // interne ne change pas l'URL, donc le ShopShell ne sait pas qu'on
    // est passé sur Membres et le bouton « + » de la topbar shell ne
    // s'affiche pas. Avec ce sync, /parametres/shop ↔ /parametres/users
    // suit le tap utilisateur.
    _tab.addListener(_syncUrlWithTab);
    _loadMembers();
  }

  @override
  void dispose() {
    _tab.removeListener(_syncUrlWithTab);
    _tab.dispose();
    super.dispose();
  }

  void _syncUrlWithTab() {
    // Évite de re-pousser pendant l'animation. On agit seulement quand
    // l'index a vraiment changé (post-animation OU swipe terminé).
    if (_tab.indexIsChanging) return;
    if (!mounted) return;
    // Membres → /parametres/users (active le bouton « + » dans la topbar
    // shell). Boutique/Copier → URL générique /parametres/shop. Pour
    // Copier on ajoute `tab=copy` car le path /parametres/shop seul est
    // ambigu (Boutique vs Copier) — sans ce marqueur, le push démontait
    // la page et la reconstruisait avec l'onglet Boutique par défaut,
    // d'où le clignotement Copier→Boutique signalé.
    final isMembers = _tab.index == _membersIndex;
    final isCopy    = _tab.index == _copyIndex && !isMembers;
    final basePath  = isMembers
        ? '/shop/${widget.shopId}/parametres/users'
        : '/shop/${widget.shopId}/parametres/shop';
    final queryParts = <String>[
      if (widget.showOverviewTab) 'with_overview=1',
      if (isCopy)                 'tab=copy',
    ];
    final target = queryParts.isEmpty
        ? basePath
        : '$basePath?${queryParts.join('&')}';
    final loc = GoRouterState.of(context).matchedLocation;
    final currentQuery = GoRouterState.of(context).uri.query;
    final currentFull = currentQuery.isEmpty ? loc : '$loc?$currentQuery';
    if (currentFull != target) context.go(target);
  }

  Future<void> _loadMembers() async {
    setState(() => _loadingMembers = true);
    try {
      final m = await AppDatabase.getShopMembers(widget.shopId);
      if (mounted) setState(() => _members = m);
    } finally {
      if (mounted) setState(() => _loadingMembers = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shop = ref.watch(currentShopProvider);
    return Column(children: [
      // ── Tab Bar ────────────────────────────────────────────────
      _TabBar(controller: _tab, tabs: _tabs),
      // ── Contenu ────────────────────────────────────────────────
      Expanded(
        child: TabBarView(
          controller: _tab,
          children: [
            if (widget.showOverviewTab)
              _OverviewTab(shop: shop, shopId: widget.shopId),
            EmployeesPage(
              shopId:          widget.shopId,
              embedInScaffold: false,
            ),
            _CopyTab(shopId: widget.shopId, onSnack: _snack, ref: ref),
          ],
        ),
      ),
    ]);
  }

  void _snack(String msg, {required bool success}) {
    if (!mounted) return;
    success ? AppSnack.success(context, msg) : AppSnack.error(context, msg);
  }
}

// ─── Tab Bar ──────────────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final TabController controller;
  final List<({IconData icon, String label})> tabs;
  const _TabBar({required this.controller, required this.tabs});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            controller: controller,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textHint,
            indicatorColor: AppColors.primary,
            indicatorWeight: 2,
            labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 11),
            tabs: tabs.map((t) => Tab(
              height: 48,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(t.icon, size: 16),
                  const SizedBox(height: 3),
                  Text(t.label),
                ],
              ),
            )).toList(),
          ),
          Container(height: 1, color: const Color(0xFFF0F0F0)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ONGLET 1 — BOUTIQUE
// ═══════════════════════════════════════════════════════════════════════════════

class _OverviewTab extends ConsumerStatefulWidget {
  final ShopSummary? shop;
  final String shopId;
  const _OverviewTab({required this.shop, required this.shopId});
  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  static const _flags = {
    'CM': '🇨🇲', 'SN': '🇸🇳', 'CI': '🇨🇮', 'NG': '🇳🇬',
    'GH': '🇬🇭', 'MA': '🇲🇦', 'FR': '🇫🇷', 'BE': '🇧🇪',
    'US': '🇺🇸', 'GB': '🇬🇧', 'CD': '🇨🇩',
  };

  static String _countryName(String iso) => switch (iso) {
    'CM' => 'Cameroun',     'SN' => 'Sénégal',     'CI' => 'Côte d\'Ivoire',
    'NG' => 'Nigeria',      'GH' => 'Ghana',       'MA' => 'Maroc',
    'FR' => 'France',       'BE' => 'Belgique',    'US' => 'États-Unis',
    'GB' => 'Royaume-Uni',  'CD' => 'R.D. Congo',
    _ => iso,
  };

  static String _currencyName(String code) => switch (code) {
    'XAF' => 'Franc CFA (Afrique Centrale)',
    'XOF' => 'Franc CFA (Afrique de l\'Ouest)',
    'EUR' => 'Euro',
    'USD' => 'US Dollar',
    'GBP' => 'Livre sterling',
    'MAD' => 'Dirham marocain',
    'NGN' => 'Naira',
    'GHS' => 'Cedi',
    _ => code,
  };

  static String _sectorLabel(String s) => switch (s) {
    'retail'      => 'Commerce de détail',
    'restaurant'  => 'Restaurant / Restauration',
    'supermarche' => 'Supermarché',
    'pharmacie'   => 'Pharmacie',
    _             => s,
  };

  static String _formatPhone(String raw, String country) {
    final clean = raw.replaceAll(RegExp(r'\s'), '');
    if (clean.startsWith('+')) return raw;
    // Fallback : préfixe XAF/CM → +237
    if (country == 'CM' && clean.length == 9) return '+237 $clean';
    return raw;
  }

  Future<void> _toggleActive(BuildContext context, ShopSummary s) async {
    final l = context.l10n;
    final activating = !s.isActive;
    await OwnerPinDialog.guard(
      context: context,
      title: activating
          ? 'Activer ${s.name}'
          : 'Désactiver ${s.name}',
      onConfirmed: () async {
        try {
          await AppDatabase.setShopActive(s.id, activating);
          ref.invalidate(currentShopProvider);
          if (mounted) {
            AppSnack.success(context, activating
                ? l.shopStatusActive : l.shopStatusInactive);
          }
        } catch (e) {
          if (mounted) AppSnack.error(context, e.toString());
        }
      },
    );
  }

  void _shareShop(BuildContext context, ShopSummary s) {
    final l = context.l10n;
    final buf = StringBuffer()
      ..writeln(s.name)
      ..writeln('${l.shopInfoCountry} : ${_countryName(s.country)}')
      ..writeln('${l.shopInfoCurrency} : ${s.currency}')
      ..writeln('${l.shopInfoSector} : ${_sectorLabel(s.sector)}');
    if (s.phone != null)  buf.writeln('${l.shopInfoPhone} : ${s.phone}');
    if (s.email != null)  buf.writeln('${l.shopInfoEmail} : ${s.email}');
    Share.share(buf.toString(), subject: l.shopShareSubject);
  }

  void _editShop(BuildContext context, ShopSummary s) {
    context.push('/shop-selector/edit/${s.id}');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (widget.shop == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = widget.shop!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Hero card (fond primary + avatar + badges + actions) ────
        _ShopHeroCard(
          shop: s,
          onShare: () => _shareShop(context, s),
          onEdit:  () => _editShop(context, s),
        ),
        const SizedBox(height: 16),

        // ── Informations enrichies — ordre spec round 3 :
        //    Pays · Devise · Secteur · Téléphone · (Email) · Statut ·
        //    UUID (en dernier). UUID était auparavant en premier champ.
        _Card(
          child: Column(children: [
            _InfoRow(
              icon: Icons.public_rounded,
              iconColor: AppColors.secondary,
              label: l.shopInfoCountry,
              value: '${_flags[s.country] ?? '🏳'}  ${_countryName(s.country)}',
            ),
            _Divider(),
            _InfoRow(
              icon: Icons.payments_outlined,
              iconColor: AppColors.warning,
              label: l.shopInfoCurrency,
              value: '${s.currency} — ${_currencyName(s.currency)}',
            ),
            _Divider(),
            _InfoRow(
              icon: Icons.category_outlined,
              iconColor: AppColors.primary,
              label: l.shopInfoSector,
              value: _sectorLabel(s.sector),
            ),
            if (s.phone != null && s.phone!.isNotEmpty) ...[
              _Divider(),
              _InfoRow(
                icon: Icons.phone_outlined,
                iconColor: AppColors.secondary,
                label: l.shopInfoPhone,
                value: _formatPhone(s.phone!, s.country),
                canCopy: true,
              ),
            ],
            if (s.email != null && s.email!.isNotEmpty) ...[
              _Divider(),
              _InfoRow(
                icon: Icons.email_outlined,
                iconColor: AppColors.primary,
                label: l.shopInfoEmail,
                value: s.email!,
                canCopy: true,
              ),
            ],
          ]),
        ),
        const SizedBox(height: 16),

        // ── Statut avec toggle Switch ──────────────────────────────
        _Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Container(width: 10, height: 10,
                decoration: BoxDecoration(
                    color: s.isActive
                        ? AppColors.secondary : AppColors.error,
                    shape: BoxShape.circle)),
              const SizedBox(width: 12),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(l.shopInfoStatus,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10,
                        color: AppColors.textHint,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(s.isActive
                        ? l.shopStatusActive : l.shopStatusInactive,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: s.isActive
                            ? AppColors.secondary : AppColors.error)),
                Text(s.isActive
                        ? l.shopStatusDescActive
                        : l.shopStatusDescInactive,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11,
                        color: AppColors.textSecondary)),
              ])),
              Switch(
                value: s.isActive,
                onChanged: (_) => _toggleActive(context, s),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),

        // ── UUID — déplacé en dernier (spec round 3). Plus accessible
        // pour copie debug / support, mais hors du flux d'info principal.
        _Card(
          child: _InfoRow(
            icon: Icons.tag_rounded,
            iconColor: AppColors.textSecondary,
            label: l.shopInfoId,
            value: s.id,
            valueMono: true,
            canCopy: true,
          ),
        ),
      ],
    );
  }
}

class _ShopHeroCard extends StatelessWidget {
  final ShopSummary shop;
  final VoidCallback onShare;
  final VoidCallback onEdit;
  const _ShopHeroCard({required this.shop,
      required this.onShare, required this.onEdit});

  String _sectorLabel(String s) => switch (s) {
    'retail'      => 'Commerce',
    'restaurant'  => 'Restaurant',
    'supermarche' => 'Supermarché',
    'pharmacie'   => 'Pharmacie',
    _             => s,
  };

  IconData _sectorIcon(String s) => switch (s) {
    'restaurant'  => Icons.restaurant_rounded,
    'supermarche' => Icons.local_grocery_store_rounded,
    'pharmacie'   => Icons.local_pharmacy_rounded,
    _             => Icons.storefront_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: AppColors.primary.withOpacity(0.25),
              blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // Avatar (logo ou initiale secteur)
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.22),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(_sectorIcon(shop.sector),
                color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(shop.name, style: const TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w800,
                  color: Colors.white, letterSpacing: -0.3),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                _HeroBadge(
                  text: shop.isActive
                      ? l.shopStatusActive : l.shopStatusInactive,
                  dotColor: shop.isActive
                      ? AppColors.secondary : AppColors.error,
                ),
                _HeroBadge(text: shop.currency),
                _HeroBadge(text: _sectorLabel(shop.sector)),
              ]),
            ],
          )),
        ]),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: onShare,
              icon: const Icon(Icons.ios_share_rounded, size: 16),
              label: Text(l.shopActionShare),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withOpacity(0.5)),
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: Text(l.shopActionEdit),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.primary,
                elevation: 0,
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontSize: 12,
                    fontWeight: FontWeight.w800),
              ),
            ),
          ]),
      ]),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  final String text;
  final Color? dotColor;
  const _HeroBadge({required this.text, this.dotColor});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.22),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (dotColor != null) ...[
        Container(width: 6, height: 6,
          decoration: BoxDecoration(
              color: dotColor, shape: BoxShape.circle)),
        const SizedBox(width: 5),
      ],
      Text(text, style: const TextStyle(fontSize: 10,
          color: Colors.white, fontWeight: FontWeight.w700)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// ONGLET 2 — MEMBRES
// ═══════════════════════════════════════════════════════════════════════════════

class _MembersTab extends StatelessWidget {
  final String shopId;
  final List<Map<String, dynamic>> members;
  final bool loading;
  final VoidCallback onRefresh;
  final void Function(String, {required bool success}) onSnack;
  const _MembersTab({
    required this.shopId,
    required this.members,
    required this.loading,
    required this.onRefresh,
    required this.onSnack,
  });

  /// Catégorise un membre selon son rôle.
  /// `owner` = propriétaire boutique (rôle = owner OU shopOwnerId == userId)
  /// `admin` = rôle admin
  /// `staff` = manager / cashier / viewer / autre
  String _category(Map<String, dynamic> m, String? ownerId) {
    final role = m['role'] as String? ?? 'cashier';
    if (role == 'owner') return 'owner';
    final uid = m['user_id'] as String?;
    if (ownerId != null && uid == ownerId) return 'owner';
    if (role == 'admin') return 'admin';
    return 'staff';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final currentUserId = LocalStorageService.getCurrentUser()?.id ?? '';
    final shop = LocalStorageService.getShop(shopId);
    final ownerId = shop?.ownerId;
    final owners = members.where((m) => _category(m, ownerId) == 'owner').toList();
    final admins = members.where((m) => _category(m, ownerId) == 'admin').toList();
    final staff  = members.where((m) => _category(m, ownerId) == 'staff').toList();
    final activeCount = members.where((m) {
      final s = m['status'] as String?;
      return s == null || s == 'active';
    }).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Topbar : titre « Membres » + CTA + Nouveau membre ─────────
        Row(children: [
          Expanded(child: Text(l.paramEmployes,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary))),
          _PrimaryBtn(
            label: l.shopMembersAddNew,
            icon: Icons.person_add_rounded,
            onTap: () => _checkQuotaAndInvite(
                context, shopId, members.length, onSnack, onRefresh),
          ),
        ]),
        const SizedBox(height: 12),

        // ── Stats 3 colonnes : Total · Actifs · Admins X/3 ───────────
        // Spec round 9 prompt 3 : gap 5px sur mobile (vs 8 desktop).
        Builder(builder: (ctx) {
          final gap = MediaQuery.of(ctx).size.width < 600 ? 5.0 : 8.0;
          return Row(children: [
            Expanded(child: _MembersStat(
                label: l.shopStatTotal,
                value: '${members.length}')),
            SizedBox(width: gap),
            Expanded(child: _MembersStat(
                label: l.shopStatActive,
                value: '$activeCount',
                valueColor: AppColors.secondary)),
            SizedBox(width: gap),
            Expanded(child: _MembersStat(
                label: l.shopStatAdmins,
                value: '${admins.length}/3',
                valueColor: AppColors.primary)),
          ]);
        }),
        const SizedBox(height: 14),

        // ── Grille des rôles (4 cards avec icône, nom, description) ──
        const _RoleGrid(),
        const SizedBox(height: 14),

        if (loading)
          const Center(child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator()))
        else if (members.isEmpty)
          _EmptyMembers(
            onInvite: () => _checkQuotaAndInvite(
                context, shopId, members.length, onSnack, onRefresh),
          )
        else ...[
          // ── Section Propriétaire (liseré gauche 3px primary, pas de
          // bouton supprimer pour l'owner — protégé spec round 3).
          if (owners.isNotEmpty) _MembersSection(
            title: l.shopSectionOwner,
            members: owners,
            shopId: shopId,
            currentUserId: currentUserId,
            highlighted: true,
            allowRemove: false,
            onRefresh: onRefresh,
          ),
          if (owners.isNotEmpty) const SizedBox(height: 12),
          // ── Section Admins ─────────────────────────────────────────
          _MembersSection(
            title: l.shopSectionAdmins,
            members: admins,
            shopId: shopId,
            currentUserId: currentUserId,
            highlighted: false,
            allowRemove: true,
            onRefresh: onRefresh,
          ),
          const SizedBox(height: 12),
          // ── Section Personnel ──────────────────────────────────────
          _MembersSection(
            title: l.shopSectionStaff,
            members: staff,
            shopId: shopId,
            currentUserId: currentUserId,
            highlighted: false,
            allowRemove: true,
            onRefresh: onRefresh,
            emptyHint: l.shopSectionStaffEmpty,
          ),
        ],
      ],
    );
  }

  Future<bool> _confirmRemove(BuildContext context) async {
    bool ok = false;
    await AppConfirmDialog.show(
      context: context,
      icon: Icons.person_remove_outlined,
      iconColor: AppColors.error,
      title: 'Retirer ce membre ?',
      body: const Text('Il perdra l\'accès à cette boutique.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      cancelLabel: 'Annuler',
      confirmLabel: 'Retirer',
      confirmColor: AppColors.error,
      onConfirm: () => ok = true,
    );
    return ok;
  }

  /// Pré-check quota utilisateurs : si limite atteinte → UpgradeSheet,
  /// sinon ouvre le dialog d'invitation.
  void _checkQuotaAndInvite(BuildContext context, String shopId,
      int currentMemberCount,
      void Function(String, {required bool success}) onSnack,
      VoidCallback onRefresh) {
    final container = ProviderScope.containerOf(context, listen: false);
    final plan = container.read(currentPlanProvider);
    if (!plan.canAddUser(currentMemberCount)) {
      UpgradeSheet.showQuota(context,
          label:    context.l10n.paramEmployes,
          current:  currentMemberCount,
          max:      plan.maxUsersPerShop);
      return;
    }
    _showInviteDialog(context, shopId, onSnack, onRefresh);
  }

  void _showInviteDialog(BuildContext context, String shopId,
      void Function(String, {required bool success}) onSnack,
      VoidCallback onRefresh) {
    final emailCtrl = TextEditingController();
    var selectedRole = UserRole.cashier;
    showDialog(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.person_add_outlined,
                  size: 16, color: AppColors.primary),
            ),
            const SizedBox(width: 10),
            const Text('Inviter un membre',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 4),
            _FieldLabel('Adresse email'),
            const SizedBox(height: 6),
            _InviteField(ctrl: emailCtrl),
            const SizedBox(height: 14),
            _FieldLabel('Rôle'),
            const SizedBox(height: 6),
            ...UserRole.values.map((r) => _RoleOption(
              role: r,
              selected: selectedRole == r,
              onTap: () => setSt(() => selectedRole = r),
            )),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dc).pop(),
              child: const Text('Annuler',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            SizedBox(
              width: 120,
              child: AppPrimaryButton(
                label: 'Inviter',
                icon: Icons.send_rounded,
                onTap: () async {
                  final email = emailCtrl.text.trim();
                  if (email.isEmpty) return;
                  Navigator.of(dc).pop();
                  try {
                    final res = await AppDatabase.inviteMember(
                        shopId, email, selectedRole);
                    onRefresh();
                    final msg = res.outcome == InviteOutcome.addedImmediately
                        ? 'Membre ajouté : ${res.invitedName ?? res.email}'
                        : 'Invitation envoyée à ${res.email}';
                    onSnack(msg, success: true);
                  } catch (e) {
                    onSnack(e.toString().replaceAll('Exception: ', ''),
                        success: false);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card stat compacte pour la rangée 3 colonnes du _MembersTab.
class _MembersStat extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _MembersStat({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    // Spec round 9 prompt 3 : compactage mobile-only. value 13/label 9
    // /padding 6 sur mobile (< 600), valeurs précédentes 18/10/10 desktop.
    final isMobile = MediaQuery.of(context).size.width < 600;
    final pad      = isMobile ? 6.0 : 10.0;
    final valFs    = isMobile ? 13.0 : 18.0;
    final labelFs  = isMobile ? 9.0 : 10.0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: pad, vertical: pad),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
        Text(value,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: valFs, fontWeight: FontWeight.w800,
                color: valueColor ?? AppColors.textPrimary)),
        const SizedBox(height: 2),
        Text(label,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: labelFs, color: AppColors.textHint)),
      ]),
    );
  }
}

/// Section de membres avec en-tête + liste. Si `highlighted: true`, la
/// section a un liseré gauche 3px primary (utilisé pour Propriétaire,
/// spec round 3). Si `allowRemove: false`, le bouton retirer est masqué
/// sur chaque _MemberRow (cas du Propriétaire — non supprimable).
class _MembersSection extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> members;
  final String shopId, currentUserId;
  final bool highlighted, allowRemove;
  final VoidCallback onRefresh;
  final String? emptyHint;
  const _MembersSection({
    required this.title,
    required this.members,
    required this.shopId,
    required this.currentUserId,
    required this.highlighted,
    required this.allowRemove,
    required this.onRefresh,
    this.emptyHint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        // Liseré gauche 3px primary pour la section Propriétaire (spec).
        // Géré via un BoxDecoration avec border non-uniforme : seul le
        // côté gauche est renforcé. Material n'autorise pas border-left
        // épais asymétrique en Border.all → on superpose un Container
        // décoratif côté gauche.
      ),
      child: Stack(children: [
        if (highlighted)
          Positioned.fill(
            left: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    bottomLeft: Radius.circular(12),
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: highlighted
                        ? AppColors.primary
                        : AppColors.textSecondary,
                    letterSpacing: 0.4)),
            const SizedBox(height: 6),
            if (members.isEmpty) ...[
              const SizedBox(height: 4),
              Text(emptyHint ?? '—',
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textHint)),
            ] else
              for (var i = 0; i < members.length; i++) ...[
                _MemberRow(
                  member: members[i],
                  shopId: shopId,
                  currentUserId: currentUserId,
                  allowRemove: allowRemove,
                  onRoleChanged: (role) async {
                    final uid = members[i]['user_id'] as String?;
                    if (uid == null) return;
                    await AppDatabase.updateMemberRole(shopId, uid, role);
                    onRefresh();
                  },
                  onRemove: () async {
                    final uid = members[i]['user_id'] as String?;
                    if (uid == null) return;
                    bool ok = false;
                    await AppConfirmDialog.show(
                      context: context,
                      icon: Icons.person_remove_outlined,
                      iconColor: AppColors.error,
                      title: 'Retirer ce membre ?',
                      body: const Text('Il perdra l\'accès à cette boutique.',
                          style: TextStyle(fontSize: 13,
                              color: AppColors.textSecondary)),
                      cancelLabel: 'Annuler',
                      confirmLabel: 'Retirer',
                      confirmColor: AppColors.error,
                      onConfirm: () => ok = true,
                    );
                    if (!ok) return;
                    await AppDatabase.removeMember(shopId, uid);
                    onRefresh();
                  },
                ),
                if (i < members.length - 1) _Divider(),
              ],
          ]),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ONGLET 3 — COPIER PRODUITS
// ═══════════════════════════════════════════════════════════════════════════════

class _CopyTab extends StatelessWidget {
  final String shopId;
  final void Function(String, {required bool success}) onSnack;
  final WidgetRef ref;
  const _CopyTab({required this.shopId, required this.onSnack, required this.ref});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Header ───────────────────────────────────────────────────
        _SectionHeader(
          icon: Icons.content_copy_rounded,
          iconColor: AppColors.primary,
          title: l.shopCopyTitle,
          subtitle: l.shopCopySubtitle,
        ),
        const SizedBox(height: 14),

        // ── Action card cliquable (style secondaire) ──────────────────
        Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: () => _showCopyDialog(context),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.background,        // background-secondary
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.drive_file_move_outline,
                      color: AppColors.primary, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.shopCopyCardTitle,
                          style: const TextStyle(fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Text(l.shopCopyCardSubtitle,
                          style: const TextStyle(fontSize: 12,
                              color: AppColors.textSecondary,
                              height: 1.3)),
                    ])),
                Icon(Icons.arrow_forward_ios_rounded,
                    size: 14, color: AppColors.primary.withOpacity(0.6)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // ── Bannière info (remplace le texte gris) ────────────────────
        _InfoBanner(l.shopCopyInfo),
      ],
    );
  }

  void _showCopyDialog(BuildContext context) async {
    final l = context.l10n;
    final allShops = ref.read(myShopsProvider);
    final otherShops = allShops.where((s) => s.id != shopId).toList();
    if (otherShops.isEmpty) {
      onSnack(l.shopCopyNoOtherShop, success: false);
      return;
    }
    final products = AppDatabase.getProductsForShop(shopId);
    if (products.isEmpty) {
      onSnack(l.shopCopyNoProduct, success: false);
      return;
    }

    Product? selectedProduct;
    ShopSummary? selectedDest;

    await showDialog(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Text(l.shopCopyDialogTitle,
              style: const TextStyle(fontSize: 15,
                  fontWeight: FontWeight.w700)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            _FieldLabel(l.shopCopyFieldProduct),
            const SizedBox(height: 6),
            _StyledDropdown<Product>(
              hint: l.shopCopyPickProduct,
              value: selectedProduct,
              items: products.map((p) => DropdownMenuItem(
                  value: p,
                  child: Text(p.name, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (p) => setSt(() => selectedProduct = p),
            ),
            const SizedBox(height: 12),
            _FieldLabel(l.shopCopyFieldShop),
            const SizedBox(height: 6),
            _StyledDropdown<ShopSummary>(
              hint: l.shopCopyPickShop,
              value: selectedDest,
              items: otherShops.map((s) => DropdownMenuItem(
                  value: s,
                  child: Text(s.name,
                      style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (s) => setSt(() => selectedDest = s),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dc).pop(),
              child: Text(l.commonCancel,
                  style: const TextStyle(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: selectedProduct == null || selectedDest == null
                  ? null
                  : () async {
                Navigator.of(dc).pop();
                try {
                  await AppDatabase.copyProductToShop(
                      selectedProduct!, selectedDest!.id);
                  onSnack(l.shopCopyDone(selectedDest!.name), success: true);
                } catch (e) {
                  onSnack(
                      e.toString().replaceAll('Exception: ', ''),
                      success: false);
                }
              },
              child: Text(l.shopCopyAction),
            ),
          ],
        ),
      ),
    );
  }
}

// Onglet « Danger » retiré : voir _DangerSection dans parametres_page.dart
// pour la zone dangereuse unifiée (déconnexion, purge logs, reset boutique,
// reset boutique en gardant produits, suppression boutique, reset compte
// global, suppression compte).

// ─── Widgets atomiques réutilisables ──────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  const _Card({required this.child, this.padding});
  @override
  Widget build(BuildContext context) => Container(
    padding: padding ?? const EdgeInsets.symmetric(
        horizontal: 16, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.divider),
    ),
    child: child,
  );
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, color: AppColors.divider);
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String value;
  final Color? valueColor;
  final bool canCopy;
  final bool valueMono;
  const _InfoRow({
    required this.icon,
    this.iconColor,
    required this.label,
    required this.value,
    this.valueColor,
    this.canCopy = false,
    this.valueMono = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconC = iconColor ?? AppColors.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(children: [
        // Icône colorée dans un cercle avec teinte 12 %
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: iconC.withOpacity(0.12),
            borderRadius: BorderRadius.circular(7),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: iconC),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textHint,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      fontFamily: valueMono ? 'monospace' : null,
                      color: valueColor ?? AppColors.textPrimary)),
            ])),
        if (canCopy)
          IconButton(
            icon: const Icon(Icons.copy_rounded,
                size: 15, color: AppColors.textSecondary),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              AppSnack.success(context, context.l10n.shopCopied);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
      ]),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: iconColor),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
            const SizedBox(height: 3),
            Text(subtitle, style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary, height: 1.4)),
          ])),
    ],
  );
}

class _RoleGrid extends StatelessWidget {
  const _RoleGrid();

  static Color _color(UserRole r) => switch (r) {
    UserRole.admin   => AppColors.primary,
    UserRole.manager => AppColors.secondary,
    UserRole.cashier => AppColors.warning,
    UserRole.viewer  => AppColors.textSecondary,
  };

  static IconData _icon(UserRole r) => switch (r) {
    UserRole.admin   => Icons.admin_panel_settings_rounded,
    UserRole.manager => Icons.manage_accounts_rounded,
    UserRole.cashier => Icons.point_of_sale_rounded,
    UserRole.viewer  => Icons.visibility_rounded,
  };

  static String _desc(AppLocalizations l, UserRole r) => switch (r) {
    UserRole.admin   => l.shopRoleAdminDesc,
    UserRole.manager => l.shopRoleManagerDesc,
    UserRole.cashier => l.shopRoleCashierDesc,
    UserRole.viewer  => l.shopRoleViewerDesc,
  };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return LayoutBuilder(builder: (ctx, cons) {
      // 2 colonnes sur mobile, 4 sur desktop
      final cols = cons.maxWidth > 600 ? 4 : 2;
      final spacing = 10.0;
      final cardW = (cons.maxWidth - (cols - 1) * spacing) / cols;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.shopRolesTitle,
            style: const TextStyle(fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
                letterSpacing: 0.2)),
        const SizedBox(height: 8),
        Wrap(spacing: spacing, runSpacing: spacing,
            children: UserRole.values.map((r) => SizedBox(
              width: cardW,
              child: _RoleCard(
                role: r, color: _color(r),
                icon: _icon(r), description: _desc(l, r),
              ),
            )).toList()),
      ]);
    });
  }
}

class _RoleCard extends StatelessWidget {
  final UserRole role;
  final Color color;
  final IconData icon;
  final String description;
  const _RoleCard({required this.role, required this.color,
      required this.icon, required this.description});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.divider),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 17, color: color),
      ),
      const SizedBox(height: 8),
      Text(role.label,
          style: const TextStyle(fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary)),
      const SizedBox(height: 2),
      Text(description,
          style: const TextStyle(fontSize: 10,
              color: AppColors.textSecondary, height: 1.3)),
    ]),
  );
}

class _MemberRow extends StatelessWidget {
  final Map<String, dynamic> member;
  final String shopId, currentUserId;
  final void Function(UserRole) onRoleChanged;
  final VoidCallback onRemove;
  /// Si `false`, masque le bouton retirer (cas Propriétaire — protégé).
  final bool allowRemove;
  const _MemberRow({
    required this.member,
    required this.shopId,
    required this.currentUserId,
    required this.onRoleChanged,
    required this.onRemove,
    this.allowRemove = true,
  });

  @override
  Widget build(BuildContext context) {
    // Supabase/Hive peut renvoyer un Map<dynamic, dynamic> pour les jointures
    // (PostgREST → JSON décodé en Map non typé). Conversion sécurisée en
    // Map<String, dynamic> via .from() pour éviter le TypeError au build.
    final profilesRaw = member['profiles'];
    final profile = profilesRaw is Map
        ? Map<String, dynamic>.from(profilesRaw)
        : null;
    final name    = profile?['name'] as String? ?? 'Inconnu';
    final email   = profile?['email'] as String? ?? '';
    final userId  = (member['user_id'] as String?) ?? '';
    final roleStr = member['role'] as String? ?? 'cashier';
    final role    = UserRole.values.firstWhere(
            (r) => r.key == roleStr, orElse: () => UserRole.cashier);
    final status  = member['status'] as String? ?? 'active';
    final isActive = status == 'active';
    final isSelf  = userId.isNotEmpty && userId == currentUserId;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final avatarColor = _avatarColor(userId);
    final permRatio = _permRatio(role);

    final isMobile = MediaQuery.of(context).size.width < 600;
    // Dimensions compactées sur mobile (spec round 9 prompt 3) :
    // avatar 32 (vs 36), nom 11 (vs 13), email 9 (vs 11), point statut
    // 5 (vs 10), perm bar 40×2 (vs 60×5). Avatar fond primarySurface
    // fixe (vs hash color) pour matcher pile la spec « primarySurface
    // + initiales primary-800 (= primary) ».
    final avatarSize = isMobile ? 32.0 : 36.0;
    final initialFs  = isMobile ? 13.0 : 14.0;
    final nameFs     = isMobile ? 11.0 : 13.0;
    final emailFs    = isMobile ? 9.0  : 11.0;
    final statusDot  = isMobile ? 5.0  : 10.0;
    final permWidth  = isMobile ? 40.0 : 60.0;
    final permHeight = isMobile ? 2.0  : 5.0;
    return LayoutBuilder(builder: (_, c) {
      // Spec : barre progression masquée si trop étroit (mobile).
      // Seuil empirique : 320 px sur mobile (40+text+chip+actions), 360
      // sur desktop (60+text+chip+actions).
      final showPermBar = c.maxWidth >= (isMobile ? 320 : 360);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: isMobile ? 8 : 10),
        child: Row(children: [
          // Avatar : sur mobile fond primarySurface fixe (spec) ; sur
          // desktop fond avatarColor.withOpacity(0.15) (legacy round 3).
          Stack(clipBehavior: Clip.none, children: [
            Container(
              width: avatarSize, height: avatarSize,
              decoration: BoxDecoration(
                color: isMobile
                    ? AppColors.primarySurface
                    : avatarColor.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Center(child: Text(initial,
                  style: TextStyle(fontSize: initialFs,
                      fontWeight: FontWeight.w700,
                      color: isMobile ? AppColors.primary : avatarColor))),
            ),
            // Point statut bas-droit : vert = actif, gris = suspendu.
            Positioned(
              right: isMobile ? 0 : -1, bottom: isMobile ? 0 : -1,
              child: Container(
                width: statusDot, height: statusDot,
                decoration: BoxDecoration(
                  color: isActive ? AppColors.secondary : AppColors.textHint,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Theme.of(context).colorScheme.surface,
                      width: isMobile ? 1 : 2),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 10),
          // Infos — nom + email (ellipsis) ; "Vous" inline si self.
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(child: Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: nameFs,
                          fontWeight: isMobile
                              ? FontWeight.w500
                              : FontWeight.w600,
                          color: AppColors.textPrimary))),
                  if (isSelf) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('Vous',
                          style: TextStyle(fontSize: 9,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
                Text(email,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: emailFs, color: AppColors.textHint)),
              ])),
          if (showPermBar) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: permWidth,
              child: Tooltip(
                message: '${(permRatio * 100).round()}%',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: permRatio,
                    minHeight: permHeight,
                    backgroundColor: AppColors.inputFill,
                    valueColor: AlwaysStoppedAnimation(AppColors.primary),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          // Badge rôle (cliquable si allowRemove pour changer rôle, sinon
          // simple display). Le Propriétaire reste affiché en chip mais
          // non éditable.
          if (allowRemove && !isSelf)
            PopupMenuButton<UserRole>(
              initialValue: role,
              onSelected: onRoleChanged,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              itemBuilder: (_) => UserRole.values.map((r) =>
                  PopupMenuItem(
                    value: r,
                    child: Row(children: [
                      Icon(_roleIcon(r), size: 14,
                          color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(r.label,
                          style: const TextStyle(fontSize: 13)),
                    ]),
                  )).toList(),
              child: _RoleChip(label: role.label, primary: false),
            )
          else
            _RoleChip(label: role.label, primary: !allowRemove || isSelf),
          // Bouton retirer — masqué pour Propriétaire (allowRemove false)
          // et pour soi-même.
          if (allowRemove && !isSelf) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.person_remove_outlined,
                  size: 16, color: AppColors.error),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                  minWidth: 28, minHeight: 28),
              tooltip: 'Retirer',
            ),
          ],
        ]),
      );
    });
  }

  /// Ratio empirique de permissions par rôle (0..1) — utilisé pour la
  /// LinearProgressIndicator. Ne reflète pas exactement la matrice
  /// AppPermissions (qui dépend aussi du plan), mais donne un signal
  /// visuel relatif suffisant pour la spec.
  double _permRatio(UserRole r) => switch (r) {
    UserRole.admin   => 1.0,
    UserRole.manager => 0.7,
    UserRole.cashier => 0.4,
    UserRole.viewer  => 0.2,
  };

  Color _avatarColor(String userId) {
    // Palette stable basée sur hash userId — Material constants pour
    // respecter la règle « zéro Color(0xFF) ».
    final colors = [
      Colors.deepPurple.shade600,
      AppColors.info,
      AppColors.secondary,
      AppColors.error,
      AppColors.warning,
      Colors.purple.shade400,
    ];
    return colors[userId.hashCode.abs() % colors.length];
  }

  IconData _roleIcon(UserRole r) => switch (r) {
    UserRole.admin   => Icons.admin_panel_settings_outlined,
    UserRole.manager => Icons.manage_accounts_outlined,
    UserRole.cashier => Icons.point_of_sale_outlined,
    UserRole.viewer  => Icons.visibility_outlined,
  };
}

/// Chip de rôle compact — primary tinted si membre protégé (self/owner)
/// sinon neutre (inputFill bg). Inclut un caret quand cliquable (parent
/// l'enveloppe d'un PopupMenuButton).
class _RoleChip extends StatelessWidget {
  final String label;
  final bool primary;
  const _RoleChip({required this.label, required this.primary});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: primary ? AppColors.primarySurface : AppColors.inputFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 11,
              fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
              color: primary ? AppColors.primary : AppColors.textSecondary)),
    );
  }
}

class _EmptyMembers extends StatelessWidget {
  final VoidCallback onInvite;
  const _EmptyMembers({required this.onInvite});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.group_outlined,
              color: AppColors.primary, size: 30),
        ),
        const SizedBox(height: 14),
        Text(l.shopEmptyMembersTitle,
            style: const TextStyle(fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        Text(l.shopEmptyMembersSubtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12,
                height: 1.4,
                color: AppColors.textSecondary)),
        const SizedBox(height: 16),
        _PrimaryBtn(
          label: l.shopEmptyMembersCta,
          icon: Icons.person_add_outlined,
          onTap: onInvite,
          fullWidth: true,
        ),
      ]),
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool fullWidth;
  const _PrimaryBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final btn = ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
    // IntrinsicWidth force une contrainte bornée quand le bouton est placé
    // dans un parent qui lui passe minWidth/maxWidth infinies (Column avec
    // CrossAxisAlignment.stretch, certains parents scrollables, etc.).
    return fullWidth
        ? SizedBox(width: double.infinity, child: btn)
        : IntrinsicWidth(child: btn);
  }
}

class _InfoBanner extends StatelessWidget {
  final String text;
  const _InfoBanner(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.info.withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.info.withOpacity(0.25)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.info_outline, size: 16, color: AppColors.info),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: const TextStyle(fontSize: 11,
              color: AppColors.textPrimary, height: 1.4))),
    ]),
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(text, style: const TextStyle(
        fontSize: 11, fontWeight: FontWeight.w600,
        color: AppColors.textSecondary)),
  );
}

class _InviteField extends StatelessWidget {
  final TextEditingController ctrl;
  const _InviteField({required this.ctrl});
  @override
  Widget build(BuildContext context) => TextFormField(
    controller: ctrl,
    autofocus: true,
    keyboardType: TextInputType.emailAddress,
    style: const TextStyle(fontSize: 13),
    decoration: InputDecoration(
      hintText: 'exemple@email.com',
      hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 13),
      prefixIcon: const Icon(Icons.email_outlined, size: 16,
          color: Color(0xFFAAAAAA)),
      filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.divider)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.divider)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
          BorderSide(color: AppColors.primary, width: 1.5)),
    ),
  );
}

class _RoleOption extends StatelessWidget {
  final UserRole role;
  final bool selected;
  final VoidCallback onTap;
  const _RoleOption({required this.role, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? AppColors.primarySurface : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: selected
                ? AppColors.primary
                : AppColors.divider),
      ),
      child: Row(children: [
        Icon(_icon(role), size: 14,
            color: selected
                ? AppColors.primary
                : AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(role.label,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.primary
                          : const Color(0xFF374151))),
              Text(_desc(role),
                  style: const TextStyle(fontSize: 10,
                      color: AppColors.textHint)),
            ])),
        if (selected)
          Icon(Icons.check_circle_rounded, size: 16, color: AppColors.primary),
      ]),
    ),
  );

  IconData _icon(UserRole r) => switch (r) {
    UserRole.admin   => Icons.admin_panel_settings_outlined,
    UserRole.manager => Icons.manage_accounts_outlined,
    UserRole.cashier => Icons.point_of_sale_outlined,
    UserRole.viewer  => Icons.visibility_outlined,
  };

  String _desc(UserRole r) => switch (r) {
    UserRole.admin   => 'Accès complet à la boutique',
    UserRole.manager => 'Gestion produits et rapports',
    UserRole.cashier => 'Caisse et inventaire uniquement',
    UserRole.viewer  => 'Consultation seulement',
  };
}

class _StyledDropdown<T> extends StatelessWidget {
  final String hint;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final void Function(T?) onChanged;
  const _StyledDropdown({
    required this.hint,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    value: value,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
      filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.divider)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.divider)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
    ),
    items: items,
    onChanged: onChanged,
  );
}
// ═══════════════════════════════════════════════════════════════════════════════
// Invitations en attente — auto-chargement + annulation
// ═══════════════════════════════════════════════════════════════════════════════

class _PendingInvitations extends StatefulWidget {
  final String shopId;
  final void Function(String, {required bool success}) onSnack;
  const _PendingInvitations({required this.shopId, required this.onSnack});
  @override
  State<_PendingInvitations> createState() => _PendingInvitationsState();
}

class _PendingInvitationsState extends State<_PendingInvitations> {
  List<Map<String, dynamic>> _invitations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await AppDatabase.getPendingInvitations(widget.shopId);
    if (mounted) setState(() { _invitations = list; _loading = false; });
  }

  Future<void> _cancel(Map<String, dynamic> inv) async {
    final id = inv['id'] as String?;
    if (id == null) return;
    try {
      await AppDatabase.cancelInvitation(id);
      widget.onSnack('Invitation annulée', success: true);
      _load();
    } catch (e) {
      widget.onSnack(
        e.toString().replaceAll('Exception: ', ''), success: false);
    }
  }

  String _roleLabel(String role) => switch (role) {
    'admin'   => 'Admin',
    'manager' => 'Manager',
    _         => 'Caissier',
  };

  String _expiresLabel(String? iso) {
    if (iso == null) return '';
    final exp = DateTime.tryParse(iso);
    if (exp == null) return '';
    final days = exp.difference(DateTime.now()).inDays;
    if (days <= 0) return 'expire bientôt';
    if (days == 1) return 'expire demain';
    return 'expire dans $days jours';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_invitations.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Row(children: [
            Icon(Icons.schedule_rounded,
                size: 13, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              '${_invitations.length} invitation${_invitations.length > 1 ? 's' : ''} en attente',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.2),
            ),
          ]),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFED7AA)),
          ),
          child: Column(
            children: _invitations.asMap().entries.map((entry) {
              final i = entry.key;
              final inv = entry.value;
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Container(width: 34, height: 34,
                        decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(9)),
                        child: const Icon(Icons.mail_outline_rounded,
                            size: 17, color: AppColors.warning)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(inv['email'] as String? ?? '—',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.primarySurface,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(_roleLabel(inv['role'] as String? ?? 'cashier'),
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary)),
                        ),
                        const SizedBox(width: 6),
                        Text(_expiresLabel(inv['expires_at'] as String?),
                            style: const TextStyle(
                                fontSize: 10, color: AppColors.textHint)),
                      ]),
                    ])),
                    IconButton(
                      onPressed: () => _cancel(inv),
                      icon: const Icon(Icons.close_rounded,
                          size: 18, color: AppColors.textHint),
                      tooltip: 'Annuler l\'invitation',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 32, minHeight: 32),
                    ),
                  ]),
                ),
                if (i < _invitations.length - 1)
                  const Divider(height: 1, indent: 56,
                      color: AppColors.inputFill),
              ]);
            }).toList(),
          ),
        ),
      ],
    );
  }
}

