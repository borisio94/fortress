import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/permisions/user_plan.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/models/plan_type.dart';

// ═════════════════════════════════════════════════════════════════════════════
// SUBSCRIPTION PAGE
//
// Section 1 — Statut actuel : badge plan coloré + dates + jours restants +
//                              barre de progression.
// Section 2 — 3 cards forfaits : Starter · Pro (badge Populaire) · Business.
//             Cycle mensuel / annuel (-20%). Liste de features avec
//             checkmarks. Card du plan actuel mise en avant + bouton
//             "Plan actuel" désactivé. Autre plan → bouton "Choisir" actif.
// Section 3 — Contact admin : texte simple expliquant l'activation manuelle.
//             TODO : ajouter un bouton WhatsApp pré-rempli quand le numéro
//             admin sera connu (cf. lib/core/config/admin_config.dart).
//
// Toutes les couleurs via Theme.of(context).colorScheme + theme.semantic.
// Aucun texte hardcodé — tout via context.l10n.
// ═════════════════════════════════════════════════════════════════════════════

class SubscriptionPage extends ConsumerStatefulWidget {
  const SubscriptionPage({super.key});
  @override
  ConsumerState<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends ConsumerState<SubscriptionPage> {
  /// Cycle affiché. Mensuel ou annuel uniquement (spec : -20% sur l'annuel).
  String _cycle = 'monthly';

  // Prix par tier × cycle. Source de vérité : table SQL `plans`. Ces valeurs
  // sont dupliquées ici pour le rendu offline-first ; à terme on lira la
  // table `plans` depuis Hive cache.
  static const _prices = <PlanType, Map<String, double>>{
    PlanType.starter:  {'monthly':  5000, 'yearly':  50000},
    PlanType.pro:      {'monthly': 10000, 'yearly': 100000},
    PlanType.business: {'monthly': 25000, 'yearly': 250000},
  };

  double _priceFor(PlanType p) => _prices[p]?[_cycle] ?? 0;

  /// Pourcentage d'économie annuelle réel basé sur les prix mensuel/annuel.
  /// Pour starter : 5k×12=60k vs 50k → 17%. Pour matcher exactement -20%
  /// il faudrait UPDATE plans SET price_yearly=48000 WHERE name='starter'.
  int _savingsPct(PlanType p) {
    final m = _prices[p]?['monthly'] ?? 0;
    final y = _prices[p]?['yearly']  ?? 0;
    if (m <= 0 || y <= 0) return 0;
    final saved = (m * 12 - y) / (m * 12) * 100;
    return saved.round();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RouteNames.shopSelector);
    }
  }

  bool _switching = false;

  /// DEV ONLY — bascule directement vers le plan choisi via la RPC
  /// `dev_switch_plan`. Bypass le flux d'activation manuelle.
  /// ⚠ À retirer / restreindre avant production.
  Future<void> _onChoose(PlanType target) async {
    if (_switching) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    final planName = switch (target) {
      PlanType.starter  => 'starter',
      PlanType.pro      => 'pro',
      PlanType.business => 'business',
      PlanType.trial    => 'trial',
      PlanType.expired  => 'starter',
    };

    setState(() => _switching = true);
    try {
      await Supabase.instance.client.rpc('dev_switch_plan', params: {
        'p_plan_name': planName,
        'p_cycle':     _cycle,
      });
      // Refresh du provider → MAJ instantanée du badge "Plan actuel"
      // et des permissions dérivées du plan.
      await ref.read(subscriptionProvider.notifier).refresh();
      if (!mounted) return;
      AppSnack.success(context,
          'Plan ${_planLabel(l, target)} activé ($_cycle)');
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Erreur bascule plan : $e'),
        backgroundColor: Theme.of(context).semantic.danger,
      ));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  static String _planLabel(AppLocalizations l, PlanType p) => switch (p) {
    PlanType.trial    => l.planTrial,
    PlanType.starter  => l.planStarter,
    PlanType.pro      => l.planPro,
    PlanType.business => l.planBusiness,
    PlanType.expired  => l.planExpired,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l     = context.l10n;
    final plan  = ref.watch(currentPlanProvider);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _Topbar(onBack: _back, title: l.subTitle),
            const SizedBox(height: 18),
            // Section 1 — Statut actuel + barre de progression
            _CurrentStatusCard(plan: plan),
            const SizedBox(height: 20),
            // Section 2 — Sélecteur cycle + 3 cards
            _CycleSelector(
              current: _cycle,
              annualSavingsPct: _savingsPct(PlanType.pro),
              onChange: (c) => setState(() => _cycle = c),
            ),
            const SizedBox(height: 14),
            for (final p in const [PlanType.starter, PlanType.pro,
                PlanType.business]) ...[
              _PlanCard(
                plan:        p,
                price:       _priceFor(p),
                cycle:       _cycle,
                isCurrent:   plan.currentPlan == p,
                isPopular:   p == PlanType.pro,
                savingsPct:  _cycle == 'yearly' ? _savingsPct(p) : null,
                onChoose:    () => _onChoose(p),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 6),
            // Section 3 — Contact admin (texte simple, WhatsApp en TODO)
            _ContactAdminCard(),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// TOPBAR
// ═════════════════════════════════════════════════════════════════════════════

class _Topbar extends StatelessWidget {
  final VoidCallback onBack;
  final String       title;
  const _Topbar({required this.onBack, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return Row(children: [
      InkWell(
        onTap: onBack,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: sem.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sem.borderSubtle),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.arrow_back_ios_new_rounded,
              size: 16, color: cs.onSurface),
        ),
      ),
      const SizedBox(width: 10),
      Text(title,
          style: TextStyle(fontSize: 17,
              fontWeight: FontWeight.w800, color: cs.onSurface)),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 1 — Statut actuel + barre de progression
// ═════════════════════════════════════════════════════════════════════════════

class _CurrentStatusCard extends StatelessWidget {
  final UserPlan plan;
  const _CurrentStatusCard({required this.plan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    // Couleur + label + total cycle (jours) selon l'état du plan.
    final Color  accent;
    final IconData icon;
    final String label;
    final String dateLine;
    // Total de jours servant de dénominateur pour la barre de progression.
    // Trial=7, mensuel=30, annuel=365. Faute de cycle dans UserPlan, on
    // déduit par la valeur de daysRemaining (≤7 → trial, ≤30 → mensuel,
    // sinon annuel). Approximatif mais visuellement correct.
    int totalDays;
    int daysLeft = plan.daysRemaining;

    if (plan.isExpired || plan.isBlocked || !plan.hasPlan) {
      accent    = sem.danger;
      icon      = Icons.lock_clock_rounded;
      label     = l.planExpired;
      dateLine  = plan.expiresAt != null
          ? '${l.subExpiredOn} ${_fmt(plan.expiresAt!)}'
          : '';
      totalDays = 1;
      daysLeft  = 0;
    } else if (plan.isTrial) {
      accent    = sem.warning;
      icon      = Icons.hourglass_top_rounded;
      label     = l.planTrial;
      dateLine  = plan.expiresAt != null
          ? '${l.subTrialUntil} ${_fmt(plan.expiresAt!)}'
          : '';
      totalDays = 7;
    } else if (plan.isActive) {
      accent    = plan.expiresSoon ? sem.warning : sem.success;
      icon      = Icons.verified_rounded;
      label     = plan.planLabel;
      dateLine  = plan.expiresAt != null
          ? '${l.subActiveUntil} ${_fmt(plan.expiresAt!)}'
          : '';
      totalDays = daysLeft <= 30 ? 30 : 365;
    } else {
      accent    = sem.warning;
      icon      = Icons.help_outline_rounded;
      label     = l.planExpired;
      dateLine  = '';
      totalDays = 1;
      daysLeft  = 0;
    }

    final progress = totalDays <= 0
        ? 1.0
        : ((totalDays - daysLeft) / totalDays).clamp(0.0, 1.0);
    final daysText = daysLeft == 1 ? l.subDayLeft : l.subDaysLeft;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.30), width: 1.2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header : icône + badge plan + jours restants à droite
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.subCurrentStatus,
                style: TextStyle(fontSize: 11,
                    color: cs.onSurface.withOpacity(0.55),
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(label,
                  style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w800, color: accent)),
            ),
          ])),
          if (plan.isActive || plan.isTrial)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$daysLeft',
                  style: TextStyle(fontSize: 22,
                      fontWeight: FontWeight.w800, color: accent)),
              Text(daysText,
                  style: TextStyle(fontSize: 10,
                      color: cs.onSurface.withOpacity(0.55))),
            ]),
        ]),
        if (dateLine.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(dateLine,
              style: TextStyle(fontSize: 12,
                  color: cs.onSurface.withOpacity(0.7),
                  fontWeight: FontWeight.w500)),
        ],
        const SizedBox(height: 12),
        // Barre de progression
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: accent.withOpacity(0.14),
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
        if (plan.isActive || plan.isTrial) ...[
          const SizedBox(height: 4),
          Text(l.subDaysOverTotal(daysLeft, totalDays),
              style: TextStyle(fontSize: 10,
                  color: cs.onSurface.withOpacity(0.5))),
        ],
      ]),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 2 — Sélecteur cycle (mensuel / annuel)
// ═════════════════════════════════════════════════════════════════════════════

class _CycleSelector extends StatelessWidget {
  final String  current;
  final int     annualSavingsPct;
  final ValueChanged<String> onChange;
  const _CycleSelector({
    required this.current,
    required this.annualSavingsPct,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: sem.trackMuted,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        for (final c in const ['monthly', 'yearly'])
          Expanded(child: GestureDetector(
            onTap: () => onChange(c),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: current == c ? cs.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(c == 'yearly'
                        ? l.subBillYearly
                        : l.subBillMonthly,
                    style: TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: current == c
                            ? cs.onPrimary
                            : cs.onSurface.withOpacity(0.7))),
                if (c == 'yearly' && annualSavingsPct > 0) ...[
                  const SizedBox(height: 1),
                  Text(l.subSavingsAnnual(annualSavingsPct),
                      style: TextStyle(fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: current == c
                              ? cs.onPrimary.withOpacity(0.85)
                              : sem.success)),
                ],
              ]),
            ),
          )),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 2 — Card forfait avec bouton par card
// ═════════════════════════════════════════════════════════════════════════════

class _PlanCard extends StatelessWidget {
  final PlanType    plan;
  final double      price;
  final String      cycle;
  final bool        isCurrent;
  final bool        isPopular;
  /// `null` si cycle = mensuel (pas d'économie à afficher).
  final int?        savingsPct;
  final VoidCallback onChoose;
  const _PlanCard({
    required this.plan,
    required this.price,
    required this.cycle,
    required this.isCurrent,
    required this.isPopular,
    required this.savingsPct,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final lim   = PlanLimits.fallback(plan);
    final accent = switch (plan) {
      PlanType.starter  => sem.info,
      PlanType.pro      => cs.primary,
      PlanType.business => sem.warning,
      _                 => cs.primary,
    };
    final label = switch (plan) {
      PlanType.starter  => l.planStarter,
      PlanType.pro      => l.planPro,
      PlanType.business => l.planBusiness,
      _                 => '',
    };
    final priceSuffix = cycle == 'yearly' ? l.subYearlyShort
                                          : l.subMonthlyShort;

    return Stack(clipBehavior: Clip.none, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        decoration: BoxDecoration(
          color: sem.elevatedSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent ? accent : sem.borderSubtle,
            width: isCurrent ? 1.8 : 1,
          ),
          // Card du plan actuel : ombrage léger pour la mettre en avant.
          boxShadow: isCurrent
              ? [BoxShadow(
                  color: accent.withOpacity(0.12),
                  blurRadius: 12, offset: const Offset(0, 4))]
              : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          // Header : nom + prix
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(label,
                style: TextStyle(fontSize: 17,
                    fontWeight: FontWeight.w800, color: cs.onSurface)),
            const Spacer(),
            Text('${_compact(price)} XAF',
                style: TextStyle(fontSize: 18,
                    fontWeight: FontWeight.w800, color: accent)),
            const SizedBox(width: 2),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(priceSuffix,
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withOpacity(0.55))),
            ),
          ]),
          if (savingsPct != null && savingsPct! > 0) ...[
            const SizedBox(height: 4),
            Text(l.subSavingsAnnual(savingsPct!),
                style: TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w700, color: sem.success)),
          ],
          const SizedBox(height: 14),
          // Liste features avec checkmarks
          ..._featuresOf(l, lim).map((line) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Icon(Icons.check_circle_rounded,
                  size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(child: Text(line,
                  style: TextStyle(fontSize: 12.5,
                      height: 1.35, color: cs.onSurface))),
            ]),
          )),
          const SizedBox(height: 12),
          // Bouton par card : "Plan actuel" désactivé OU "Choisir" actif
          SizedBox(
            width: double.infinity, height: 42,
            child: isCurrent
                ? OutlinedButton(
                    onPressed: null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      disabledForegroundColor: accent,
                      side: BorderSide(color: accent.withOpacity(0.45)),
                      backgroundColor: accent.withOpacity(0.08),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                      Icon(Icons.check_rounded, size: 16, color: accent),
                      const SizedBox(width: 6),
                      Text(l.subCurrentPlanBadge,
                          style: TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w700, color: accent)),
                    ]),
                  )
                : ElevatedButton(
                    onPressed: onChoose,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: cs.onPrimary,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(l.subChoosePlan,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
          ),
        ]),
      ),
      // Badge "Populaire" en haut à droite (Pro uniquement)
      if (isPopular)
        Positioned(
          top: -8, right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(
                  color: cs.primary.withOpacity(0.35),
                  blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.star_rounded, size: 12, color: cs.onPrimary),
              const SizedBox(width: 4),
              Text(l.subPopularBadge,
                  style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w800, color: cs.onPrimary)),
            ]),
          ),
        ),
    ]);
  }

  /// Lignes textuelles affichées avec checkmarks. Combinaison limites + features.
  List<String> _featuresOf(AppLocalizations l, PlanLimits lim) {
    final lines = <String>[
      l.subMaxShops(lim.maxShops),
      l.subMaxUsers(lim.maxUsersPerShop),
      l.subMaxProducts(lim.maxProducts),
    ];
    if (lim.offlineEnabled) lines.add(l.subOfflineYes);
    for (final f in lim.features) {
      lines.add(_featureLabel(l, f));
    }
    return lines;
  }

  static String _compact(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(0)}k';
    return v.toStringAsFixed(0);
  }

  static String _featureLabel(AppLocalizations l, Feature f) {
    switch (f) {
      case Feature.multiShop:        return l.featMultiShop;
      case Feature.advancedReports:  return l.featAdvancedReports;
      case Feature.csvExport:        return l.featCsvExport;
      case Feature.finances:         return l.featFinances;
      case Feature.apiIntegration:   return l.featApiIntegration;
      case Feature.whatsappAuto:     return l.featWhatsappAuto;
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SECTION 3 — Contact admin (texte simple, WhatsApp en TODO)
// ═════════════════════════════════════════════════════════════════════════════

class _ContactAdminCard extends StatelessWidget {
  // TODO : ajouter un bouton "Contacter via WhatsApp" qui ouvre wa.me avec
  //         AdminConfig.whatsappAdminNumber et un message pré-rempli (plan
  //         + cycle + user_id + email). Voir lib/core/config/admin_config.dart.
  //         Désactivé pour l'instant tant que le numéro admin n'est pas
  //         configuré en prod.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final l     = context.l10n;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withOpacity(0.18)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.support_agent_rounded,
              size: 18, color: cs.primary),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.subContactAdminTitle,
              style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w800, color: cs.onSurface)),
          const SizedBox(height: 4),
          Text(l.subContactAdminBody,
              style: TextStyle(fontSize: 12, height: 1.5,
                  color: cs.onSurface.withOpacity(0.7))),
        ])),
      ]),
    );
  }
}
