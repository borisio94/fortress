import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../core/validators/input_validators.dart';
import '../widgets/settings_widgets.dart';

class UserProfilePage extends ConsumerStatefulWidget {
  final String? shopId;
  const UserProfilePage({super.key, this.shopId});

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _currentPwdCtrl = TextEditingController();
  final _newPwdCtrl = TextEditingController();
  final _confirmPwdCtrl = TextEditingController();

  bool _editing = false;
  bool _saving = false;
  String _email = '';
  String? _initialName;
  String? _initialPhone;

  @override
  void initState() {
    super.initState();
    final user = LocalStorageService.getCurrentUser();
    _nameCtrl.text = user?.name ?? '';
    _phoneCtrl.text = user?.phone ?? '';
    _email = user?.email ?? '';
    _initialName = user?.name;
    _initialPhone = user?.phone;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _currentPwdCtrl.dispose();
    _newPwdCtrl.dispose();
    _confirmPwdCtrl.dispose();
    super.dispose();
  }

  bool get _hasChanges =>
      _editing &&
      (_nameCtrl.text.trim() != (_initialName ?? '') ||
          _phoneCtrl.text.trim() != (_initialPhone ?? ''));

  Future<void> _saveProfile() async {
    final l = context.l10n;
    if (_nameCtrl.text.trim().length < 3) {
      AppSnack.error(context, l.errNameTooShort);
      return;
    }
    setState(() => _saving = true);
    try {
      final user = LocalStorageService.getCurrentUser();
      if (user == null) return;

      // Mise à jour profiles Supabase
      await Supabase.instance.client.from('profiles').update({
        'name': _nameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
      }).eq('id', user.id);

      // Mise à jour cache local
      final updated = user.copyWith(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      );
      await LocalStorageService.saveUser(updated);

      if (!mounted) return;
      setState(() {
        _initialName = updated.name;
        _initialPhone = updated.phone;
        _editing = false;
      });
      AppSnack.success(context, l.profileSaved);
    } catch (e) {
      if (mounted) AppSnack.error(context, '${l.commonError}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changePassword() async {
    final l = context.l10n;
    final pwdErr = InputValidators.password(_newPwdCtrl.text);
    if (pwdErr != null) {
      AppSnack.error(context, pwdErr);
      return;
    }
    if (_newPwdCtrl.text != _confirmPwdCtrl.text) {
      AppSnack.error(context, l.errPasswordMismatch);
      return;
    }
    setState(() => _saving = true);
    try {
      final auth = Supabase.instance.client.auth;
      // Ré-auth pour valider le mot de passe actuel
      await auth.signInWithPassword(
        email: _email,
        password: _currentPwdCtrl.text.trim(),
      );
      await auth.updateUser(
          UserAttributes(password: _newPwdCtrl.text.trim()));
      if (!mounted) return;
      _currentPwdCtrl.clear();
      _newPwdCtrl.clear();
      _confirmPwdCtrl.clear();
      AppSnack.success(context, l.profilePasswordChanged);
    } catch (e) {
      if (mounted) AppSnack.error(context, '${l.commonError}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _initials(String name) {
    if (name.trim().isEmpty) return '?';
    return name
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase())
        .take(2)
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppScaffold(
      shopId: widget.shopId ?? '',
      title: l.profileTitle,
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AvatarHeader(
            initials: _initials(_nameCtrl.text),
            name: _nameCtrl.text,
            email: _email,
          ),
          const SizedBox(height: 20),
          SettingsSectionCard(
            title: l.paramCompte,
            children: [
              SettingsField(
                label: l.profileName,
                controller: _nameCtrl,
                enabled: _editing,
              ),
              SettingsField(
                label: l.profileEmail,
                controller: TextEditingController(text: _email),
                enabled: false,
                trailing: const Icon(Icons.lock_outline_rounded,
                    size: 16, color: Color(0xFF9CA3AF)),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 2),
                child: Text(l.profileEmailLocked,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9CA3AF))),
              ),
              SettingsField(
                label: l.profilePhone,
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                enabled: _editing,
              ),
              const SizedBox(height: 8),
              Row(children: [
                if (!_editing)
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.primary),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: Text(l.profileSave == 'Enregistrer'
                          ? 'Modifier'
                          : 'Edit'),
                      onPressed: () => setState(() => _editing = true),
                    ),
                  )
                else ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                                _editing = false;
                                _nameCtrl.text = _initialName ?? '';
                                _phoneCtrl.text = _initialPhone ?? '';
                              }),
                      child: Text(l.commonCancel),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: (_saving || !_hasChanges) ? null : _saveProfile,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text(l.commonSave),
                    ),
                  ),
                ],
              ]),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionCard(
            title: l.profileChangePassword,
            children: [
              PasswordField(
                controller: _currentPwdCtrl,
                label: l.profileCurrentPassword,
                hint: '••••••••',
              ),
              const SizedBox(height: 12),
              PasswordStrengthField(
                controller: _newPwdCtrl,
                label: l.profileNewPassword,
                hint: '••••••••',
              ),
              const SizedBox(height: 12),
              ConfirmPasswordField(
                controller: _confirmPwdCtrl,
                originalController: _newPwdCtrl,
                label: l.profileConfirmNewPassword,
                hint: '••••••••',
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _saving ? null : _changePassword,
                  child: Text(l.profileChangePassword),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarHeader extends StatelessWidget {
  final String initials;
  final String name;
  final String email;
  const _AvatarHeader({
    required this.initials,
    required this.name,
    required this.email,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primary, AppColors.primaryLight],
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.25),
                shape: BoxShape.circle,
                border:
                    Border.all(color: Colors.white.withOpacity(0.4), width: 2),
              ),
              child: Center(
                child: Text(initials,
                    style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
            ),
            const SizedBox(height: 12),
            Text(name.isEmpty ? '—' : name,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 2),
            Text(email,
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withOpacity(0.85))),
          ],
        ),
      );
}
