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
  /// Orientation : null = pas encore répondu, true = a déjà un Pixel,
  /// false = doit en créer un. Pilote l'aide affichée.
  bool? _hasPixel;

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

  // Contourne l'app Meta Business Suite (qui capte les liens facebook.com sur
  // mobile) : l'utilisateur colle le lien dans Safari/Chrome → reste dans le
  // navigateur, où la « version ordinateur » donne accès aux évènements de test.
  void _copyTestEventsLink(String pixelId) {
    Clipboard.setData(ClipboardData(text: _testEventsUrl(pixelId)));
    AppSnack.success(context, 'Lien copié — collez-le dans Safari ou Chrome');
  }

  // Lien vers le Gestionnaire d'évènements (trouver / créer le Pixel). Même
  // parade mobile : coller dans le navigateur pour éviter l'app Business Suite.
  void _copyEventsManagerLink() {
    Clipboard.setData(const ClipboardData(text: _kEventsManagerUrl));
    AppSnack.success(context, 'Lien copié — collez-le dans Safari ou Chrome');
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

  // ─── Carte de connexion (orientée nouvel utilisateur) ─────────────────────

  Widget _connectCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Connecter votre Pixel Facebook',
                style: AppTextStyles.bodyBold),
            const SizedBox(height: 4),
            const Text('Suivez les ventes générées par vos publicités.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 14),

            // Recommandation : le plus simple, depuis un ordinateur.
            _recoBanner(),
            const SizedBox(height: 18),

            // Orientation : a-t-il déjà un Pixel ?
            const Text('Avez-vous déjà un Pixel Facebook ?',
                style: AppTextStyles.bodyBold),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _choiceChip('Oui, j\'en ai un', _hasPixel == true,
                    () => setState(() => _hasPixel = true)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _choiceChip('Non, pas encore', _hasPixel == false,
                    () => setState(() => _hasPixel = false)),
              ),
            ]),

            if (_hasPixel == true)
              _metaAccessBlock(
                title: 'Trouvez l\'ID de votre Pixel',
                body: 'Gestionnaire d\'évènements → ouvrez votre source de '
                    'données → l\'ID (15-16 chiffres) s\'affiche juste sous le '
                    'nom. Copiez-le et collez-le ci-dessous.',
              ),
            if (_hasPixel == false)
              _metaAccessBlock(
                title: 'Créez votre Pixel (gratuit)',
                body: 'Gestionnaire d\'évènements → « Connecter des sources de '
                    'données » → « Web ». Suivez les étapes, notez l\'ID du '
                    'Pixel créé, puis revenez le coller ici.',
              ),

            const SizedBox(height: 18),

            // Saisie de l'ID — toujours disponible.
            const Text('Collez votre ID Pixel ici',
                style: AppTextStyles.bodyBold),
            const SizedBox(height: 8),
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
            const SizedBox(height: 6),
            const Text(
                'C\'est l\'ID affiché dans le Gestionnaire d\'évènements — '
                'pas l\'ID du portefeuille business.',
                style: AppTextStyles.captionHint),
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

  /// Bandeau de recommandation : configurer depuis un ordinateur (Meta cache
  /// le Gestionnaire d'évènements sur mobile).
  Widget _recoBanner() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kFacebookBlue.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kFacebookBlue.withValues(alpha: 0.2)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.computer, size: 18, color: _kFacebookBlue),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Le plus simple : faites cette configuration une fois depuis '
                'un ordinateur. Sur téléphone, Meta cache le Gestionnaire '
                'd\'évènements.',
                style: AppTextStyles.captionHint,
              ),
            ),
          ],
        ),
      );

  /// Puce de choix (orientation Oui / Non).
  Widget _choiceChip(String label, bool selected, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: selected
                ? _kFacebookBlue.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? _kFacebookBlue : AppColors.divider,
                width: selected ? 1.5 : 1),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 16,
                color: selected ? _kFacebookBlue : AppColors.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color:
                          selected ? _kFacebookBlue : AppColors.textPrimary)),
            ),
          ]),
        ),
      );

  /// Bloc d'accès Meta (trouver OU créer le Pixel) : explication + ouverture +
  /// copier le lien (parade mobile) + note « version ordinateur ».
  Widget _metaAccessBlock({required String title, required String body}) =>
      Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTextStyles.bodyBold),
            const SizedBox(height: 4),
            Text(body, style: AppTextStyles.captionHint),
            const SizedBox(height: 10),
            _outlinedAction(
              icon: Icons.open_in_new_rounded,
              label: 'Ouvrir le Gestionnaire d\'évènements',
              onTap: _openEventsManager,
            ),
            const SizedBox(height: 8),
            _outlinedAction(
              icon: Icons.copy_rounded,
              label: 'Copier le lien (pour Safari/Chrome)',
              onTap: _copyEventsManagerLink,
            ),
            _mobileHint(),
          ],
        ),
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
            Text('Où trouver l\'ID de votre Pixel',
                style: AppTextStyles.bodyBold),
            SizedBox(height: 8),
            _HelpLine('1.',
                'Le plus fiable : sur un ordinateur, allez sur '
                'business.facebook.com/events_manager2.'),
            _HelpLine('2.',
                'Ouvrez « Ensembles de données » (à gauche) → votre Pixel → '
                'l\'ID (15-16 chiffres) s\'affiche juste sous le nom.'),
            _HelpLine('!',
                'Page vide « Connecter les données » ? Vous êtes sur le '
                'MAUVAIS portefeuille : cliquez le nom du compte en haut à '
                'gauche et changez-en (votre Pixel est dans un autre).'),
            _HelpLine('•',
                'Toujours rien ? Vérifiez le compte Facebook connecté (photo '
                'en haut à droite).'),
            _HelpLine('•',
                'À ne pas confondre avec l\'ID du portefeuille business '
                '(autre numéro, dans Paramètres de l\'entreprise).'),
            _HelpLine('•',
                'Sur téléphone : copiez le lien ci-dessus, collez-le dans '
                'Safari/Chrome, puis activez « version pour ordinateur ».'),
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
            const SizedBox(height: 8),
            _outlinedAction(
              icon: Icons.copy_rounded,
              label: 'Copier le lien des évènements de test',
              onTap: () => _copyTestEventsLink(pixelId),
            ),
            _mobileHint(),
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

  /// Note mobile : Meta redirige `business.facebook.com` vers Business Suite
  /// mobile (sans Gestionnaire d'évènements). Le mode « version ordinateur »
  /// du navigateur contourne cette redirection.
  Widget _mobileHint() => const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded,
                size: 14, color: AppColors.textSecondary),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'Sur téléphone, activez « Voir version pour ordinateur » dans '
                'le menu de votre navigateur si la page d\'évènements ne '
                's\'ouvre pas.',
                style: AppTextStyles.captionHint,
              ),
            ),
          ],
        ),
      );

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
