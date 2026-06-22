import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';

/// Couleur de marque Facebook (#1877F2). Constante de marque tierce — pas un
/// token de thème Fortress, figée volontairement.
const Color _kFacebookBlue = Color(0xFF1877F2);

/// Origine du site public (Firebase Hosting). Même base que le partage
/// catalogue (cf. share_catalog_dialog.dart) → liens cohérents.
const String _kSiteOrigin = 'https://fortress-pos.web.app';

/// Base du Gestionnaire d'évènements Meta (vue d'ensemble). Ouverte dans un
/// nouvel onglet. Utilisée à l'étape 1 (l'ID du dataset n'est pas encore
/// connu). Une fois le pixel connecté, on utilise un lien profond vers le
/// dataset (cf. [_testEventsUrl]) — bien plus fiable.
const String _kEventsManagerUrl = 'https://business.facebook.com/events_manager2';

/// Lien profond vers l'onglet « Évènements de test » d'un dataset précis.
/// Format canonique Meta : `.../events_manager2/list/dataset/<id>/test_events`.
String _testEventsUrl(String pixelId) =>
    'https://business.facebook.com/events_manager2/list/dataset/$pixelId/test_events';

/// Page « Marketing » : connecter le Pixel Facebook en moins de 2 minutes,
/// sans jargon. Guide visuel en 3 étapes, validation locale de l'ID, test
/// intégré et partage du lien catalogue.
class MarketingPage extends ConsumerStatefulWidget {
  final String shopId;
  const MarketingPage({super.key, required this.shopId});

  @override
  ConsumerState<MarketingPage> createState() => _MarketingPageState();
}

class _MarketingPageState extends ConsumerState<MarketingPage> {
  final _pixelCtrl = TextEditingController();
  bool _saving = false;
  bool _helpOpen = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pixelCtrl.text = ref.read(currentShopProvider)?.facebookPixelId ?? '';
  }

  @override
  void dispose() {
    _pixelCtrl.dispose();
    super.dispose();
  }

  String get _catalogueUrl => '$_kSiteOrigin/catalogue/${widget.shopId}';

  /// Un ID de pixel Meta est purement numérique (15-16 chiffres en pratique).
  /// On tolère 10-20 pour rester souple sans accepter n'importe quoi.
  bool _isValidId(String v) => RegExp(r'^[0-9]{10,20}$').hasMatch(v);

  Future<void> _connect() async {
    final id = _pixelCtrl.text.trim();
    if (!_isValidId(id)) {
      setState(() => _error =
          'Cet ID ne semble pas correct. Vérifiez dans Meta Ads Manager.');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await AppDatabase.updateShop(shopId: widget.shopId, facebookPixelId: id);
      ref.invalidate(currentShopProvider);
      if (!mounted) return;
      AppSnack.success(context,
          'Pixel connecté — votre catalogue est maintenant lié à Facebook !');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec de la connexion : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _saving = true);
    try {
      // Chaîne vide → null côté AppDatabase.updateShop (déconnexion).
      await AppDatabase.updateShop(shopId: widget.shopId, facebookPixelId: '');
      ref.invalidate(currentShopProvider);
      _pixelCtrl.clear();
      if (!mounted) return;
      AppSnack.success(context, 'Pixel déconnecté');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _copyLink() {
    Clipboard.setData(ClipboardData(text: _catalogueUrl));
    AppSnack.success(context, 'Lien copié');
  }

  // openExternal doit suivre le clic dans le même tick (cf. doc) → pas d'await
  // avant l'appel.
  Future<void> _shareWhatsapp() {
    final msg = 'Découvrez notre catalogue en ligne : $_catalogueUrl';
    return openExternal('https://wa.me/?text=${Uri.encodeComponent(msg)}');
  }

  Future<void> _openCatalogue() => openExternal(_catalogueUrl);
  Future<void> _openEventsManager() => openExternal(_kEventsManagerUrl);

  @override
  Widget build(BuildContext context) {
    final shop = ref.watch(currentShopProvider);
    final pixelId = (shop?.facebookPixelId ?? '').trim();
    final connected = pixelId.isNotEmpty;
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Marketing',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _headerCard(connected),
          const SizedBox(height: 16),
          if (connected) _connectedCard(pixelId) else _connectCard(),
          const SizedBox(height: 16),
          _catalogueLinkCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ─── Briques visuelles ────────────────────────────────────────────────────

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: child,
      );

  Widget _headerCard(bool connected) => _card(
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _kFacebookBlue,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.facebook, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Facebook & Instagram', style: AppTextStyles.bodyBold),
                SizedBox(height: 2),
                Text('Connectez votre catalogue à vos pubs',
                    style: AppTextStyles.captionHint),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _statusBadge(connected),
        ]),
      );

  Widget _statusBadge(bool connected) {
    final color = connected ? AppColors.secondary : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(connected ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 14, color: color),
        const SizedBox(width: 5),
        Text(connected ? 'Connecté' : 'Non connecté',
            style: AppTextStyles.caption
                .copyWith(color: color, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  // ─── Carte de connexion (guide 3 étapes) ──────────────────────────────────

  Widget _connectCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Connecter votre Pixel Facebook',
                style: AppTextStyles.bodyBold),
            const SizedBox(height: 4),
            const Text(
                'Suivez les ventes générées par vos publicités. '
                '3 étapes, moins de 2 minutes.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 18),

            // Étape 1
            _step(
              1,
              'Ouvrez Meta Ads Manager',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _outlinedAction(
                    icon: Icons.open_in_new_rounded,
                    label: 'Ouvrir Meta Ads Manager',
                    onTap: _openEventsManager,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                      'Gestionnaire d\'évènements → cliquez sur votre '
                      'ensemble de données → copiez l\'ID affiché sous le nom.',
                      style: AppTextStyles.captionHint),
                ],
              ),
            ),

            // Étape 2
            _step(
              2,
              'Copiez votre ID Pixel',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _idIllustration(),
                  const SizedBox(height: 6),
                  const Text('L\'ID est un nombre à 15-16 chiffres.',
                      style: AppTextStyles.captionHint),
                ],
              ),
            ),

            // Étape 3
            _step(
              3,
              'Collez-le ici',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppField(
                    controller: _pixelCtrl,
                    hint: 'Ex: 123456789012345',
                    prefixIcon: Icons.tag_rounded,
                    numbersOnly: true,
                    keyboardType: TextInputType.number,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.error_outline_rounded,
                          size: 15, color: AppColors.warning),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(_error!,
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.warning)),
                      ),
                    ]),
                  ],
                ],
              ),
              isLast: true,
            ),

            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Connecter mon Pixel',
              icon: Icons.link_rounded,
              isLoading: _saving,
              onTap: _connect,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _helpOpen = !_helpOpen),
                icon: Icon(
                    _helpOpen
                        ? Icons.expand_less_rounded
                        : Icons.help_outline_rounded,
                    size: 18),
                label: const Text('Comment trouver mon ID Pixel ?'),
                style: TextButton.styleFrom(
                    foregroundColor: _kFacebookBlue,
                    padding: EdgeInsets.zero),
              ),
            ),
            if (_helpOpen) _helpBlock(),
          ],
        ),
      );

  /// Étape numérotée : pastille + titre + contenu, avec un trait vertical de
  /// liaison (sauf la dernière).
  Widget _step(int n, String title, Widget child, {bool isLast = false}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: _kFacebookBlue, shape: BoxShape.circle),
              child: Text('$n',
                  style: AppTextStyles.caption.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            if (!isLast)
              Expanded(
                child: Container(width: 2, color: AppColors.divider),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.bodyBold),
                  const SizedBox(height: 8),
                  child,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _idIllustration() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(children: [
          Text('ID ',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary)),
          Text('123456789012345',
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.underline,
              )),
        ]),
      );

  Widget _helpBlock() => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kFacebookBlue.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kFacebookBlue.withValues(alpha: 0.2)),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Où trouver l\'ID dans Meta', style: AppTextStyles.bodyBold),
            SizedBox(height: 8),
            _HelpLine('1.', 'Connectez-vous à business.facebook.com.'),
            _HelpLine('2.', 'Menu de gauche → « Gestionnaire d\'évènements ».'),
            _HelpLine('3.',
                'Sélectionnez votre ensemble de données (votre Pixel).'),
            _HelpLine('4.',
                'Le numéro affiché juste sous le nom est votre ID Pixel.'),
            _HelpLine('5.', 'Copiez ce nombre et collez-le ci-dessus.'),
          ],
        ),
      );

  // ─── Carte « connecté » (test rapide + déconnexion) ───────────────────────

  Widget _connectedCard(String pixelId) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.check_circle_rounded,
                  color: AppColors.secondary, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('Pixel connecté', style: AppTextStyles.bodyBold),
              ),
            ]),
            const SizedBox(height: 4),
            Text('ID $pixelId',
                style: AppTextStyles.captionHint.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary)),
            const Divider(height: 26),

            const Text('Testez votre connexion', style: AppTextStyles.bodyBold),
            const SizedBox(height: 4),
            const Text(
                'Ouvrez votre catalogue, parcourez un produit, puis vérifiez '
                'que votre Pixel reçoit des évènements dans Meta → '
                'Évènements de test.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            _outlinedAction(
              icon: Icons.storefront_rounded,
              label: 'Ouvrir mon catalogue',
              onTap: _openCatalogue,
            ),
            const SizedBox(height: 8),
            _outlinedAction(
              icon: Icons.open_in_new_rounded,
              label: 'Voir les évènements de test',
              onTap: () => openExternal(_testEventsUrl(pixelId)),
            ),
            const Divider(height: 26),

            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving ? null : _disconnect,
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('Déconnecter'),
                style: TextButton.styleFrom(
                    foregroundColor: AppColors.error,
                    padding: EdgeInsets.zero),
              ),
            ),
          ],
        ),
      );

  // ─── Carte « lien catalogue » ─────────────────────────────────────────────

  Widget _catalogueLinkCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Votre lien catalogue', style: AppTextStyles.bodyBold),
            const SizedBox(height: 4),
            const Text(
                'Partagez ce lien dans vos pubs Facebook, sur votre page ou '
                'sur WhatsApp.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.divider),
              ),
              child: Text(_catalogueUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body
                      .copyWith(color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _outlinedAction(
                  icon: Icons.copy_rounded,
                  label: 'Copier',
                  onTap: _copyLink,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _outlinedAction(
                  icon: Icons.share_rounded,
                  label: 'Partager sur WhatsApp',
                  onTap: _shareWhatsapp,
                ),
              ),
            ]),
          ],
        ),
      );

  // ─── Bouton secondaire générique ──────────────────────────────────────────

  Widget _outlinedAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: BorderSide(color: AppColors.divider),
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      );
}

/// Ligne d'aide numérotée (puce + texte).
class _HelpLine extends StatelessWidget {
  final String bullet;
  final String text;
  const _HelpLine(this.bullet, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(bullet,
                style: AppTextStyles.caption
                    .copyWith(fontWeight: FontWeight.w800)),
          ),
          Expanded(child: Text(text, style: AppTextStyles.caption)),
        ],
      ),
    );
  }
}
