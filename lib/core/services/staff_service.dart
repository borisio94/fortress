import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/payslip.dart';
import '../../features/restaurant/domain/entities/salary_advance.dart';
import '../../features/restaurant/domain/entities/shift_evaluation.dart';
import '../../features/restaurant/domain/entities/staff_absence.dart';
import '../../features/restaurant/domain/entities/staff_member.dart';
import '../../features/restaurant/domain/entities/staff_penalty.dart';
import '../../features/restaurant/domain/entities/time_record.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import 'activity_log_service.dart';
import 'staff_contest_service.dart';

/// Personnel du restaurant : fiches, pointage, avances et paie (Lot D).
///
/// Ids `em_` (employé) · `tc_` (pointage) · `sa_` (avance) · `pr_` (paie),
/// + microsecondes. Push Supabase via `bgUpsert`.
///
/// Concerne le PERSONNEL (serveuses, cuisiniers), pas les utilisateurs de
/// l'application — cf. [StaffMember].
class StaffService {
  StaffService._();

  static Box<Map> _staffBox() => HiveBoxes.employeesBox;
  static Box<Map> _timeBox() => HiveBoxes.timeRecordsBox;
  static Box<Map> _advanceBox() => HiveBoxes.salaryAdvancesBox;
  static Box<Map> _payrollBox() => HiveBoxes.payrollBox;
  static Box<Map> _penaltyBox() => HiveBoxes.staffPenaltiesBox;
  static Box<Map> _absenceBox() => HiveBoxes.staffAbsencesBox;

  static String _id(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

  // ── Personnel ───────────────────────────────────────────────────────────

  /// Membres du personnel, actifs d'abord, puis par ordre alphabétique.
  static List<StaffMember> forShop(String shopId, {bool onlyActive = false}) {
    try {
      final list = <StaffMember>[];
      for (final raw in _staffBox().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final s = StaffMember.fromMap(Map<String, dynamic>.from(raw));
          if (onlyActive && !s.isActive) continue;
          list.add(s);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
      });
      return list;
    } catch (e) {
      debugPrint('[Staff] forShop err: $e');
      return [];
    }
  }

  static StaffMember? byId(String shopId, String id) {
    try {
      final raw = _staffBox().get(id);
      if (raw == null) return null;
      final s = StaffMember.fromMap(Map<String, dynamic>.from(raw));
      return s.shopId == shopId ? s : null;
    } catch (_) {
      return null;
    }
  }

  static Future<StaffMember> saveMember(StaffMember s) async {
    await _put(_staffBox(), 'employees', s.shopId, s.id, s.toMap());
    return s;
  }

  static Future<StaffMember> createMember({
    required String shopId,
    required String fullName,
    String role = '',
    int baseSalary = 0,
    DateTime? hireDate,
    String? phone,
    String? station,
    bool hasAppAccess = true,
    String? closingTime,
  }) async {
    final s = StaffMember(
      id: _id('em'),
      shopId: shopId,
      fullName: fullName.trim(),
      role: role.trim(),
      baseSalary: baseSalary,
      hireDate: hireDate ?? DateTime.now(),
      phone: phone,
      station: station,
      hasAppAccess: hasAppAccess,
      closingTime: closingTime,
      createdAt: DateTime.now(),
    );
    return saveMember(s);
  }

  /// Archive un membre du personnel plutôt que de le supprimer : ses pointages
  /// et ses fiches de paie doivent rester lisibles après son départ.
  static Future<void> deactivate(StaffMember s) =>
      saveMember(s.copyWith(isActive: false));

  static Future<void> deleteMember(String id, String shopId) async {
    try {
      await _staffBox().delete(id);
    } catch (e) {
      debugPrint('[Staff] delete err: $e');
    }
    AppDatabase.bgDelete('employees', val: id);
    AppDatabase.notifyListeners('employees', shopId);
  }

  /// SUPPRESSION DÉFINITIVE d'une fiche, avec son motif (hotfix_166).
  ///
  /// Seule la FICHE part. Les pointages, avances et bulletins de l'intéressé
  /// restent : ils portent son nom figé et alimentent des totaux déjà
  /// vérifiés. Les effacer changerait rétroactivement des masses salariales et
  /// des clôtures de caisse que quelqu'un a signées.
  ///
  /// Le motif part au journal d'activité AVANT la suppression : une fois la
  /// fiche partie, plus rien ne dit qui a été supprimé ni pourquoi, et c'est
  /// précisément la question qu'on se posera.
  static Future<void> deleteMemberWithReason(
      StaffMember m, String reason) async {
    await ActivityLogService.log(
      action: 'staff_deleted',
      targetType: 'employee',
      targetId: m.id,
      targetLabel: m.fullName,
      shopId: m.shopId,
      details: {
        'reason': reason.trim(),
        'role': m.role,
        'base_salary': m.baseSalary,
        'had_pin': m.hasPin,
      },
    );
    await deleteMember(m.id, m.shopId);
  }

  // ── Code de pointage ────────────────────────────────────────────────────

  /// Sel aléatoire de 16 octets, un par employé.
  static String _generateSalt() {
    final rng = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => rng.nextInt(256)));
  }

  /// SHA-256(sel:PIN) — jamais le PIN en clair, ces lignes sont synchronisées
  /// sur tous les appareils de la boutique. Même schéma que `PinService`.
  @visibleForTesting
  static String hashPin(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Un PIN de pointage valide : exactement 4 chiffres.
  static bool isValidPin(String pin) =>
      pin.length == 4 && RegExp(r'^\d{4}$').hasMatch(pin);

  /// Définit (ou remplace) le code de pointage d'un employé.
  static Future<StaffMember?> setPin(StaffMember s, String pin) async {
    if (!isValidPin(pin)) return null;
    final salt = _generateSalt();
    return saveMember(s.copyWith(pinHash: hashPin(pin, salt), pinSalt: salt));
  }

  static Future<StaffMember> clearPin(StaffMember s) =>
      saveMember(s.copyWith(clearPin: true));

  /// Retrouve l'employé ACTIF dont le code correspond, ou `null`.
  ///
  /// Balaie les employés plutôt que d'indexer par PIN : les codes sont hachés
  /// avec un sel différent chacun, il n'existe donc pas de valeur commune à
  /// rechercher. Quelques dizaines de comparaisons SHA-256, c'est instantané.
  ///
  /// En cas de PIN identique entre deux employés — seules les fiches créées
  /// avant [pinOwner] peuvent l'être, la saisie le refuse désormais — le
  /// PREMIER par ordre alphabétique gagne.
  static StaffMember? findByPin(String shopId, String pin) {
    if (!isValidPin(pin)) return null;
    for (final s in forShop(shopId, onlyActive: true)) {
      if (!s.hasPin) continue;
      if (hashPin(pin, s.pinSalt!) == s.pinHash) return s;
    }
    return null;
  }

  // ── Unicité d'une fiche ─────────────────────────────────────────────────
  //
  // Deux fiches pour une même personne, c'est un mois de salaire coupé en deux
  // et des heures qui tombent tantôt d'un côté tantôt de l'autre. Le nom ne
  // suffit pas à les rapprocher (« Awa Ndiaye » / « awa ndiaye »), et deux
  // homonymes existent vraiment. Restent deux repères qui n'appartiennent qu'à
  // une personne : son code de pointage et son numéro.
  //
  // Le balayage porte sur TOUT le personnel, archivés compris : une fiche
  // archivée se réactive d'un bouton, et le doublon ressurgirait à ce
  // moment-là — trop tard pour l'expliquer.

  /// Clé de comparaison d'un contact : chiffres seuls.
  ///
  /// `+237 6 99 12 34 56`, `237699123456` et `699 12 34 56` sont le même
  /// appareil. On compare donc sur les 9 derniers chiffres — longueur d'un
  /// numéro camerounais — pour qu'un indicatif tapé une fois sur deux ne fasse
  /// pas passer un doublon. Chaîne vide si aucun chiffre : un contact non
  /// renseigné n'entre en collision avec rien.
  static String phoneKey(String? phone) {
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    return digits.length > 9 ? digits.substring(digits.length - 9) : digits;
  }

  /// L'employé de cette liste qui porte déjà ce contact, ou `null`.
  static StaffMember? phoneOwnerIn(
    Iterable<StaffMember> members,
    String? phone, {
    String? exceptId,
  }) {
    final key = phoneKey(phone);
    if (key.isEmpty) return null;
    for (final s in members) {
      if (s.id == exceptId) continue;
      if (phoneKey(s.phone) == key) return s;
    }
    return null;
  }

  /// L'employé de cette liste qui porte déjà ce code, ou `null`.
  ///
  /// Chaque code étant haché avec son propre sel, il n'existe aucune valeur
  /// commune à rechercher : on rejoue le hachage employé par employé.
  static StaffMember? pinOwnerIn(
    Iterable<StaffMember> members,
    String pin, {
    String? exceptId,
  }) {
    if (!isValidPin(pin)) return null;
    for (final s in members) {
      if (s.id == exceptId || !s.hasPin) continue;
      if (hashPin(pin, s.pinSalt!) == s.pinHash) return s;
    }
    return null;
  }

  /// Qui utilise déjà ce code dans la boutique — actifs ET archivés.
  static StaffMember? pinOwner(String shopId, String pin, {String? exceptId}) =>
      pinOwnerIn(forShop(shopId), pin, exceptId: exceptId);

  /// Qui utilise déjà ce contact dans la boutique — actifs ET archivés.
  static StaffMember? phoneOwner(String shopId, String? phone,
          {String? exceptId}) =>
      phoneOwnerIn(forShop(shopId), phone, exceptId: exceptId);

  /// Un autre employé utilise-t-il déjà ce code ?
  static bool isPinTaken(String shopId, String pin, {String? exceptId}) =>
      pinOwner(shopId, pin, exceptId: exceptId) != null;

  /// Un autre employé utilise-t-il déjà ce contact ?
  static bool isPhoneTaken(String shopId, String? phone, {String? exceptId}) =>
      phoneOwner(shopId, phone, exceptId: exceptId) != null;

  // ── Pointage ────────────────────────────────────────────────────────────

  static List<TimeRecord> timeRecords(
    String shopId, {
    String? employeeId,
    DateTime? from,
    DateTime? to,
  }) {
    try {
      final list = <TimeRecord>[];
      for (final raw in _timeBox().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final r = TimeRecord.fromMap(Map<String, dynamic>.from(raw));
          if (employeeId != null && r.employeeId != employeeId) continue;
          final at = r.clockIn ?? r.createdAt;
          if (from != null && at.isBefore(from)) continue;
          if (to != null && at.isAfter(to)) continue;
          list.add(r);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => (b.clockIn ?? b.createdAt)
          .compareTo(a.clockIn ?? a.createdAt));
      return list;
    } catch (e) {
      debugPrint('[Staff] timeRecords err: $e');
      return [];
    }
  }

  /// Service EN COURS d'un employé (badgé à l'entrée, pas encore sorti).
  static TimeRecord? openRecord(String shopId, String employeeId) {
    for (final r in timeRecords(shopId, employeeId: employeeId)) {
      if (r.isOpen) return r;
    }
    return null;
  }

  /// Qui est actuellement en service.
  static List<TimeRecord> onDuty(String shopId) =>
      timeRecords(shopId).where((r) => r.isOpen).toList();

  // ── Horaire et taux (hotfix_165) ────────────────────────────────────────

  /// Heure de fin de service qui s'applique à CET employé, `HH:mm`.
  ///
  /// Sa surcharge d'abord, l'horaire de l'établissement ensuite. `null` = rien
  /// n'est réglé, donc rien n'est jugé : ni départ anticipé, ni heures
  /// supplémentaires. C'est le comportement d'avant la règle, et c'est ce que
  /// doit obtenir un restaurant qui n'a pas encore ouvert l'écran de réglages.
  static String? closingTimeFor(StaffMember m) =>
      m.closingTime ?? LocalStorageService.getShopClosingTime(m.shopId);

  /// Taux horaire des heures supplémentaires de la FONCTION de cet employé.
  ///
  /// 0 quand le poste n'a pas de taux : les heures sont alors comptées en
  /// minutes mais valorisées à zéro. Inventer un taux par défaut serait pire —
  /// l'établissement paierait un montant qu'il n'a jamais décidé.
  static int overtimeRateFor(StaffMember m) {
    final role = m.role.trim().toLowerCase();
    if (role.isEmpty) return 0;
    for (final e in LocalStorageService.getJobTitleRates(m.shopId).entries) {
      if (e.key.trim().toLowerCase() == role) return e.value;
    }
    return 0;
  }

  /// Badge : ouvre un service s'il n'y en a pas, le ferme sinon.
  ///
  /// Retourne le pointage résultant, le sens du badge — l'écran annonce
  /// « Bonjour » ou « Bonne fin de service » à partir de là — et, à la sortie,
  /// le VERDICT du service : parti à l'heure, trop tôt, ou en heures
  /// supplémentaires. C'est lui qui décide si la badgeuse réclame une excuse.
  ///
  /// Tout ce que la comparaison produit est FIGÉ dans le pointage : l'heure de
  /// référence, les minutes, le taux, le montant. Le gérant qui change son
  /// horaire ou le taux d'un poste en novembre ne doit pas réécrire les heures
  /// supplémentaires de septembre.
  static Future<({TimeRecord record, bool isEntry, ShiftEvaluation verdict})>
      punch(
    StaffMember member, {
    String method = 'pin',
  }) async {
    final open = openRecord(member.shopId, member.id);
    if (open != null) {
      final end = DateTime.now();
      final start = open.clockIn ?? open.createdAt;
      // L'heure de référence a été figée à l'entrée. Les pointages ouverts
      // AVANT hotfix_165 n'en ont pas : on la reconstruit alors, sinon leur
      // sortie ne serait jamais jugée.
      final scheduled =
          open.scheduledEnd ??
              ShiftEvaluation.scheduledEndFor(start, closingTimeFor(member));
      final verdict =
          ShiftEvaluation.of(clockOut: end, scheduledEnd: scheduled);
      final rate = verdict.isOvertime ? overtimeRateFor(member) : 0;
      final closed = open.copyWith(
        clockOut: end,
        durationMinutes: TimeRecord.minutesBetween(start, end),
        scheduledEnd: scheduled,
        earlyMinutes: verdict.earlyMinutes,
        overtimeMinutes: verdict.overtimeMinutes,
        overtimeRate: rate,
        overtimeAmount: ShiftEvaluation.overtimePay(
            minutes: verdict.overtimeMinutes, hourlyRate: rate),
      );
      await _put(_timeBox(), 'time_records', closed.shopId, closed.id,
          closed.toMap());
      return (record: closed, isEntry: false, verdict: verdict);
    }
    final now = DateTime.now();
    final rec = TimeRecord(
      id: _id('tc'),
      shopId: member.shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      clockIn: now,
      method: method,
      createdAt: now,
      scheduledEnd:
          ShiftEvaluation.scheduledEndFor(now, closingTimeFor(member)),
    );
    await _put(_timeBox(), 'time_records', rec.shopId, rec.id, rec.toMap());
    return (record: rec, isEntry: true, verdict: ShiftEvaluation.onTime);
  }

  // ── Départ anticipé : l'excuse et son jugement ───────────────────────────

  /// Attache l'excuse dictée par l'employé à la badgeuse. Elle passe alors
  /// « à juger » : c'est le gérant qui tranchera, jamais l'appareil.
  static Future<TimeRecord> attachExcuse(TimeRecord r, String excuse) async {
    final clean = excuse.trim();
    if (clean.isEmpty) return r;
    final next = r.copyWith(
        earlyExcuse: clean, excuseStatus: ExcuseStatus.pending);
    await _put(_timeBox(), 'time_records', next.shopId, next.id, next.toMap());
    return next;
  }

  /// Le gérant accepte ou refuse l'excuse.
  ///
  /// Un refus ne retient RIEN tout seul : il rend le départ « non justifié »,
  /// que la préparation de la paie signale. Retenir automatiquement sur un
  /// motif jugé à la main transformerait un désaccord en prélèvement, sans
  /// que personne ne l'ait décidé.
  static Future<TimeRecord> judgeExcuse(TimeRecord r, bool accepted) async {
    final next = r.copyWith(
        excuseStatus:
            accepted ? ExcuseStatus.accepted : ExcuseStatus.refused);
    await _put(_timeBox(), 'time_records', next.shopId, next.id, next.toMap());
    return next;
  }

  /// Départs anticipés dont l'excuse attend une décision.
  static List<TimeRecord> excusesToJudge(String shopId) =>
      timeRecords(shopId).where((r) => r.excuseToJudge).toList();

  // ── Heures supplémentaires ───────────────────────────────────────────────

  /// Le gérant tranche : payées de suite, ou reportées sur la paie du mois.
  ///
  /// « Payées de suite » solde immédiatement ([TimeRecord.overtimeSettled]) —
  /// l'argent sort du tiroir maintenant, et la clôture de caisse doit le
  /// déduire (cf. [cashOut]). « Sur la paie » attend la génération de la
  /// fiche, qui les portera et les soldera à ce moment-là.
  static Future<TimeRecord> settleOvertime(
      TimeRecord r, OvertimeSettlement how) async {
    final next = r.copyWith(
      overtimeSettlement: how,
      overtimeSettled: how == OvertimeSettlement.paidNow,
    );
    await _put(_timeBox(), 'time_records', next.shopId, next.id, next.toMap());
    return next;
  }

  /// Heures supplémentaires d'un employé sur un mois, PAS ENCORE réglées.
  ///
  /// Le mois est celui de la SORTIE : un service commencé le 31 à 21 h et fini
  /// le 1er à 2 h appartient au mois où il s'est terminé — c'est la nuit qui a
  /// été payée, pas la soirée.
  static List<TimeRecord> overtimeToSettle(String shopId,
      {String? employeeId, String? month, bool onlyPayslip = false}) {
    final out = <TimeRecord>[];
    for (final r in timeRecords(shopId, employeeId: employeeId)) {
      if (!r.hasOvertime || r.overtimeSettled) continue;
      if (onlyPayslip &&
          r.overtimeSettlement != OvertimeSettlement.onPayslip) {
        continue;
      }
      final at = r.clockOut ?? r.clockIn ?? r.createdAt;
      if (month != null && SalaryAdvance.monthKey(at) != month) continue;
      out.add(r);
    }
    return out;
  }

  /// Total des heures supplémentaires à porter sur la paie d'un mois.
  static ({int minutes, int amount}) pendingOvertime(
      String shopId, String employeeId, String month) {
    var minutes = 0;
    var amount = 0;
    for (final r in overtimeToSettle(shopId,
        employeeId: employeeId, month: month, onlyPayslip: true)) {
      minutes += r.overtimeMinutes;
      amount += r.overtimeAmount;
    }
    return (minutes: minutes, amount: amount);
  }

  /// Saisie manuelle d'un service par le gérant (oubli de badge).
  static Future<TimeRecord> recordManual({
    required StaffMember member,
    required DateTime start,
    required DateTime end,
    String? note,
  }) async {
    final rec = TimeRecord(
      id: _id('tc'),
      shopId: member.shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      clockIn: start,
      clockOut: end,
      durationMinutes: TimeRecord.minutesBetween(start, end),
      method: 'manual',
      note: note,
      createdAt: DateTime.now(),
    );
    await _put(_timeBox(), 'time_records', rec.shopId, rec.id, rec.toMap());
    return rec;
  }

  static Future<void> deleteTimeRecord(TimeRecord r) async {
    try {
      await _timeBox().delete(r.id);
    } catch (e) {
      debugPrint('[Staff] delete pointage err: $e');
    }
    AppDatabase.bgDelete('time_records', val: r.id);
    AppDatabase.notifyListeners('time_records', r.shopId);
  }

  /// Minutes travaillées par un employé sur un mois `YYYY-MM`.
  ///
  /// Les services EN COURS sont exclus : compter un pointage non refermé
  /// ferait grossir le total à chaque rafraîchissement de l'écran de paie.
  static int minutesInMonth(String shopId, String employeeId, String month) {
    var total = 0;
    for (final r in timeRecords(shopId, employeeId: employeeId)) {
      if (r.isOpen) continue;
      final at = r.clockIn ?? r.createdAt;
      if (SalaryAdvance.monthKey(at) != month) continue;
      total += r.durationMinutes ?? r.worked.inMinutes;
    }
    return total;
  }

  // ── Avances ─────────────────────────────────────────────────────────────

  static List<SalaryAdvance> advances(
    String shopId, {
    String? employeeId,
    String? month,
    bool? pendingOnly,
  }) {
    try {
      final list = <SalaryAdvance>[];
      for (final raw in _advanceBox().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final a = SalaryAdvance.fromMap(Map<String, dynamic>.from(raw));
          if (employeeId != null && a.employeeId != employeeId) continue;
          if (month != null && a.deductedFromMonth != month) continue;
          if (pendingOnly == true && a.isDeducted) continue;
          list.add(a);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.advanceDate.compareTo(a.advanceDate));
      return list;
    } catch (e) {
      debugPrint('[Staff] advances err: $e');
      return [];
    }
  }

  /// Total des avances NON ENCORE retenues d'un employé pour un mois donné.
  static int pendingAdvances(String shopId, String employeeId, String month) =>
      advances(shopId,
              employeeId: employeeId, month: month, pendingOnly: true)
          .fold(0, (s, a) => s + a.amount);

  static Future<SalaryAdvance> recordAdvance({
    required StaffMember member,
    required int amount,
    String? reason,
    DateTime? date,
    String? month,
    String kind = SalaryAdvance.kindAdvance,
  }) async {
    final at = date ?? DateTime.now();
    final a = SalaryAdvance(
      id: _id('sa'),
      shopId: member.shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      amount: amount,
      reason: reason,
      advanceDate: at,
      deductedFromMonth: month ?? SalaryAdvance.monthKey(at),
      kind: kind,
      createdAt: DateTime.now(),
    );
    await _put(_advanceBox(), 'salary_advances', a.shopId, a.id, a.toMap());
    return a;
  }

  /// LA QUINZAINE — la moitié du salaire, sans avoir à se justifier.
  ///
  /// Une avance d'un genre particulier : elle sort de la même caisse et se
  /// retient sur la même paie, mais elle ne se demande pas, elle se touche.
  /// D'où l'absence de motif, et le plafond ([SalaryAdvance.fortnightCap]) —
  /// au-delà ce n'est plus une quinzaine, c'est une avance, et celle-là se
  /// motive.
  static Future<SalaryAdvance> recordFortnight({
    required StaffMember member,
    required int amount,
    DateTime? date,
    String? month,
  }) =>
      recordAdvance(
        member: member,
        amount: amount,
        date: date,
        month: month,
        kind: SalaryAdvance.kindFortnight,
      );

  /// L'employé a-t-il déjà touché sa quinzaine sur ce mois ?
  ///
  /// La question que le gérant ne peut pas trancher de mémoire au bout de
  /// douze employés — et la réponse qu'il doit pouvoir opposer à celui qui
  /// revient demander la même chose une semaine plus tard.
  static int fortnightTaken(String shopId, String employeeId, String month) =>
      advances(shopId, employeeId: employeeId, month: month)
          .where((a) => a.isFortnight)
          .fold(0, (s, a) => s + a.amount);

  static Future<void> saveAdvance(SalaryAdvance a) =>
      _put(_advanceBox(), 'salary_advances', a.shopId, a.id, a.toMap());

  static Future<void> deleteAdvance(SalaryAdvance a) async {
    try {
      await _advanceBox().delete(a.id);
    } catch (e) {
      debugPrint('[Staff] delete avance err: $e');
    }
    AppDatabase.bgDelete('salary_advances', val: a.id);
    AppDatabase.notifyListeners('salary_advances', a.shopId);
  }

  // ── Casse imputée ───────────────────────────────────────────────────────

  static List<StaffPenalty> penalties(
    String shopId, {
    String? employeeId,
    bool openOnly = false,
  }) {
    try {
      final list = <StaffPenalty>[];
      for (final raw in _penaltyBox().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final p = StaffPenalty.fromMap(Map<String, dynamic>.from(raw));
          if (employeeId != null && p.employeeId != employeeId) continue;
          if (openOnly && p.isSettled) continue;
          list.add(p);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.incidentDate.compareTo(a.incidentDate));
      return list;
    } catch (e) {
      debugPrint('[Staff] penalties err: $e');
      return [];
    }
  }

  static Future<StaffPenalty> savePenalty(StaffPenalty p) async {
    await _put(_penaltyBox(), 'staff_penalties', p.shopId, p.id, p.toMap());
    return p;
  }

  static Future<StaffPenalty> recordPenalty({
    required StaffMember member,
    required String itemLabel,
    required int amount,
    required String reason,
    PenaltyMode mode = PenaltyMode.oneShot,
    int percentPerMonth = 25,
    DateTime? incidentDate,
    String? startMonth,
  }) async {
    final at = incidentDate ?? DateTime.now();
    final p = StaffPenalty(
      id: _id('pe'),
      shopId: member.shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      itemLabel: itemLabel.trim(),
      amount: amount,
      mode: mode,
      percentPerMonth: percentPerMonth,
      // Remboursée de sa poche : la dette est soldée à la seconde où elle est
      // saisie, et le salaire n'est jamais touché. L'écrire quand même sert de
      // trace — c'est arrivé, et ça compte le jour où ça se reproduit.
      amountRecovered: mode == PenaltyMode.cashRepaid ? amount : 0,
      closedAt: mode == PenaltyMode.cashRepaid ? DateTime.now() : null,
      startMonth: startMonth ?? StaffPenalty.monthKey(at),
      reason: reason.trim(),
      incidentDate: at,
      createdAt: DateTime.now(),
    );
    return savePenalty(p);
  }

  static Future<void> deletePenalty(StaffPenalty p) async {
    try {
      await _penaltyBox().delete(p.id);
    } catch (e) {
      debugPrint('[Staff] delete pénalité err: $e');
    }
    AppDatabase.bgDelete('staff_penalties', val: p.id);
    AppDatabase.notifyListeners('staff_penalties', p.shopId);
  }

  /// Ce que les pénalités d'un employé retiennent sur la paie de [month].
  static int penaltyDueFor(String shopId, String employeeId, String month) =>
      penalties(shopId, employeeId: employeeId, openOnly: true)
          .fold(0, (s, p) => s + p.dueFor(month));

  // ── Absences décidées : mise à pied, congé payé (hotfix_166) ────────────

  static List<StaffAbsence> absences(
    String shopId, {
    String? employeeId,
    bool liveOnly = false,
  }) {
    try {
      final list = <StaffAbsence>[];
      for (final raw in _absenceBox().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final a = StaffAbsence.fromMap(Map<String, dynamic>.from(raw));
          if (employeeId != null && a.employeeId != employeeId) continue;
          if (liveOnly && a.isCancelled) continue;
          list.add(a);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.startDate.compareTo(a.startDate));
      return list;
    } catch (e) {
      debugPrint('[Staff] absences err: $e');
      return [];
    }
  }

  /// L'absence qui couvre ce jour, ou `null`. LA question de la badgeuse.
  ///
  /// Une seule est retournée même s'il en existe plusieurs qui se chevauchent :
  /// l'écran n'a qu'un message à afficher, et deux absences simultanées sur la
  /// même personne sont une erreur de saisie, pas un cas à gérer.
  static StaffAbsence? absenceOn(String shopId, String employeeId,
      {DateTime? day}) {
    final d = day ?? DateTime.now();
    for (final a in absences(shopId, employeeId: employeeId, liveOnly: true)) {
      if (a.coversDay(d)) return a;
    }
    return null;
  }

  /// Qui est absent aujourd'hui, toutes causes confondues.
  static List<StaffAbsence> absentToday(String shopId, {DateTime? day}) {
    final d = day ?? DateTime.now();
    return absences(shopId, liveOnly: true)
        .where((a) => a.coversDay(d))
        .toList();
  }

  static Future<StaffAbsence> saveAbsence(StaffAbsence a) async {
    await _put(_absenceBox(), 'staff_absences', a.shopId, a.id, a.toMap());
    return a;
  }

  /// Prononce une mise à pied ou accorde un congé payé.
  ///
  /// Le motif est exigé par la signature elle-même : ces trois gestes se
  /// défendent devant l'intéressé, et une décision sans raison écrite ne se
  /// défend pas.
  static Future<StaffAbsence> recordAbsence({
    required StaffMember member,
    required AbsenceKind kind,
    required DateTime startDate,
    required DateTime endDate,
    required String reason,
    bool isPaid = false,
  }) async {
    final a = StaffAbsence(
      id: _id('ab'),
      shopId: member.shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      kind: kind,
      startDate: startDate,
      // Une fin saisie avant le début vaut une journée : refuser bloquerait
      // une absence d'un seul jour saisie de travers, ce qui est courant.
      endDate: endDate.isBefore(startDate) ? startDate : endDate,
      reason: reason.trim(),
      // Un congé payé l'est par définition — le paramètre ne peut pas le
      // contredire.
      isPaid: kind == AbsenceKind.paidLeave ? true : isPaid,
      createdAt: DateTime.now(),
    );
    return saveAbsence(a);
  }

  /// Lève une absence. La ligne est CONSERVÉE : « la mise à pied a été levée »
  /// est une information, l'effacer laisserait croire qu'elle n'a jamais eu
  /// lieu.
  static Future<StaffAbsence> cancelAbsence(StaffAbsence a) =>
      saveAbsence(a.copyWith(cancelledAt: DateTime.now()));

  static Future<void> deleteAbsence(StaffAbsence a) async {
    try {
      await _absenceBox().delete(a.id);
    } catch (e) {
      debugPrint('[Staff] delete absence err: $e');
    }
    AppDatabase.bgDelete('staff_absences', val: a.id);
    AppDatabase.notifyListeners('staff_absences', a.shopId);
  }

  /// Ce que les absences sans solde retiennent sur la paie de [month].
  static ({int amount, int days}) absenceDueFor(
      StaffMember member, String month) {
    var amount = 0;
    var days = 0;
    for (final a in absences(member.shopId,
        employeeId: member.id, liveOnly: true)) {
      final due = a.dueFor(month, member.baseSalary);
      if (due <= 0) continue;
      amount += due;
      days += a.daysInMonth(month);
    }
    return (amount: amount, days: days);
  }

  // ── Paie ────────────────────────────────────────────────────────────────

  static List<Payslip> payslips(String shopId,
      {String? employeeId, String? month}) {
    try {
      final list = <Payslip>[];
      for (final raw in _payrollBox().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final p = Payslip.fromMap(Map<String, dynamic>.from(raw));
          if (employeeId != null && p.employeeId != employeeId) continue;
          if (month != null && p.month != month) continue;
          list.add(p);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.month.compareTo(a.month));
      return list;
    } catch (e) {
      debugPrint('[Staff] payslips err: $e');
      return [];
    }
  }

  /// Fiche déjà générée pour ce couple (employé, mois), s'il y en a une.
  ///
  /// Garde-fou contre la double paie : générer deux fois le même mois
  /// retiendrait deux fois les mêmes avances, ou paierait deux fois le salaire.
  static Payslip? payslipFor(String shopId, String employeeId, String month) {
    final found = payslips(shopId, employeeId: employeeId, month: month);
    return found.isEmpty ? null : found.first;
  }

  /// Génère la fiche de paie d'un mois `YYYY-MM`.
  ///
  /// Trois choses sont SOLDÉES au passage, et c'est tout l'intérêt de générer
  /// une fiche plutôt que d'additionner à la main :
  ///   * les avances et quinzaines du mois passent à « retenues » — sans ça,
  ///     elles seraient déduites une seconde fois le mois suivant ;
  ///   * les heures supplémentaires reportées sur la paie sont marquées
  ///     réglées — sinon les mêmes heures seraient payées à chaque fiche ;
  ///   * la casse en cours de récupération encaisse sa mensualité.
  ///
  /// Les heures supplémentaires que le gérant n'a PAS encore tranchées ne sont
  /// pas portées : une décision non prise ne doit pas se prendre toute seule au
  /// moment de la paie.
  static Future<Payslip> generatePayslip({
    required StaffMember member,
    required String month,
    int bonuses = 0,
    int deductions = 0,
    String? notes,
  }) async {
    final shopId = member.shopId;
    final pending =
        advances(shopId, employeeId: member.id, month: month, pendingOnly: true);
    final advancesTotal = pending.fold<int>(0, (s, a) => s + a.amount);

    final otRecords = overtimeToSettle(shopId,
        employeeId: member.id, month: month, onlyPayslip: true);
    final otMinutes = otRecords.fold<int>(0, (s, r) => s + r.overtimeMinutes);
    final otAmount = otRecords.fold<int>(0, (s, r) => s + r.overtimeAmount);

    final openPenalties =
        penalties(shopId, employeeId: member.id, openOnly: true);
    final penaltyTotal =
        openPenalties.fold<int>(0, (s, p) => s + p.dueFor(month));

    final liveAbsences =
        absences(shopId, employeeId: member.id, liveOnly: true);
    final absenceTotal = liveAbsences.fold<int>(
        0, (s, a) => s + a.dueFor(month, member.baseSalary));
    final absenceDays = liveAbsences.fold<int>(
        0,
        (s, a) =>
            s + (a.dueFor(month, member.baseSalary) > 0
                ? a.daysInMonth(month)
                : 0));

    final slip = Payslip(
      id: _id('pr'),
      shopId: shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      month: month,
      baseSalary: member.baseSalary,
      bonuses: bonuses,
      deductions: deductions,
      advancesDeducted: advancesTotal,
      minutesWorked: minutesInMonth(shopId, member.id, month),
      overtimeAmount: otAmount,
      overtimeMinutes: otMinutes,
      penaltiesDeducted: penaltyTotal,
      absencesDeducted: absenceTotal,
      absenceDays: absenceDays,
      netSalary: Payslip.computeNet(
        baseSalary: member.baseSalary,
        bonuses: bonuses,
        deductions: deductions,
        advances: advancesTotal,
        overtime: otAmount,
        penalties: penaltyTotal,
        absences: absenceTotal,
      ),
      notes: notes,
      createdAt: DateTime.now(),
    );
    await _put(_payrollBox(), 'payroll', shopId, slip.id, slip.toMap());

    for (final a in pending) {
      await saveAdvance(a.copyWith(isDeducted: true));
    }
    for (final r in otRecords) {
      await _put(_timeBox(), 'time_records', r.shopId, r.id,
          r.copyWith(overtimeSettled: true).toMap());
    }
    for (final p in openPenalties) {
      final due = p.dueFor(month);
      if (due > 0) await savePenalty(p.recover(due));
    }
    for (final a in liveAbsences) {
      final due = a.dueFor(month, member.baseSalary);
      if (due > 0) await saveAbsence(a.deduct(due));
    }
    return slip;
  }

  /// Marque une fiche comme payée.
  static Future<Payslip> markPaid(Payslip slip) async {
    final paid = slip.copyWith(paidAt: DateTime.now());
    await _put(_payrollBox(), 'payroll', paid.shopId, paid.id, paid.toMap());
    return paid;
  }

  /// Supprime une fiche et REND tout ce qu'elle avait soldé.
  ///
  /// Trois rendus symétriques de la génération, et aucun n'est optionnel :
  ///   * les avances redeviennent dues — sinon elles resteraient « déduites »
  ///     sans qu'aucune fiche ne les porte, et l'employé les perdrait ;
  ///   * les heures supplémentaires redeviennent à régler — sinon l'employé
  ///     aurait travaillé ces heures-là pour rien ;
  ///   * la casse rend sa mensualité — sinon la dette se solderait d'un mois
  ///     que personne n'a payé.
  static Future<void> deletePayslip(Payslip slip) async {
    try {
      await _payrollBox().delete(slip.id);
    } catch (e) {
      debugPrint('[Staff] delete paie err: $e');
    }
    AppDatabase.bgDelete('payroll', val: slip.id);
    AppDatabase.notifyListeners('payroll', slip.shopId);

    if (slip.advancesDeducted > 0) {
      for (final a in advances(slip.shopId,
          employeeId: slip.employeeId, month: slip.month)) {
        if (a.isDeducted) await saveAdvance(a.copyWith(isDeducted: false));
      }
    }
    if (slip.overtimeAmount > 0 || slip.overtimeMinutes > 0) {
      for (final r in timeRecords(slip.shopId, employeeId: slip.employeeId)) {
        if (!r.hasOvertime || !r.overtimeSettled) continue;
        if (r.overtimeSettlement != OvertimeSettlement.onPayslip) continue;
        final at = r.clockOut ?? r.clockIn ?? r.createdAt;
        if (SalaryAdvance.monthKey(at) != slip.month) continue;
        await _put(_timeBox(), 'time_records', r.shopId, r.id,
            r.copyWith(overtimeSettled: false).toMap());
      }
    }
    if (slip.absencesDeducted > 0) {
      // Même plafonnement que pour la casse : on remonte les absences de
      // l'employé jusqu'à concurrence de ce que la fiche portait, pour qu'une
      // suppression répétée ne rende pas deux fois la même retenue.
      var toGiveBack = slip.absencesDeducted;
      for (final a in absences(slip.shopId, employeeId: slip.employeeId)) {
        if (toGiveBack <= 0) break;
        if (a.amountDeducted <= 0) continue;
        final back =
            a.amountDeducted < toGiveBack ? a.amountDeducted : toGiveBack;
        await saveAbsence(a.copyWith(amountDeducted: a.amountDeducted - back));
        toGiveBack -= back;
      }
    }
    if (slip.penaltiesDeducted > 0) {
      // Rendu au prorata de ce que la fiche portait : on remonte les dettes
      // de l'employé jusqu'à concurrence du total retenu. Sans ce plafond, une
      // fiche supprimée deux fois rendrait deux fois la même mensualité.
      var toGiveBack = slip.penaltiesDeducted;
      for (final p in penalties(slip.shopId, employeeId: slip.employeeId)) {
        if (toGiveBack <= 0) break;
        if (p.amountRecovered <= 0 || p.mode == PenaltyMode.cashRepaid) {
          continue;
        }
        final back =
            p.amountRecovered < toGiveBack ? p.amountRecovered : toGiveBack;
        await savePenalty(p.copyWith(
            amountRecovered: p.amountRecovered - back, clearClosedAt: true));
        toGiveBack -= back;
      }
    }
  }

  /// Espèces sorties du tiroir pour le personnel sur une période : avances
  /// versées en liquide + salaires payés en liquide.
  ///
  /// Sans cette déduction, une avance de 20 000 F prise dans la caisse apparaît
  /// le soir comme un manquant de 20 000 F — et le caissier est suspecté d'un
  /// vol qu'il n'a pas commis. C'est le faux positif qui fait abandonner la
  /// clôture aveugle.
  static int cashOut(String shopId, {DateTime? from, DateTime? to}) {
    var total = 0;
    bool inRange(DateTime d) =>
        (from == null || !d.isBefore(from)) && (to == null || !d.isAfter(to));

    for (final a in advances(shopId)) {
      // La date d'avance est une DATE (minuit) : on la compare à la journée,
      // pas à l'heure de la clôture, sinon une avance du matin sortirait de la
      // fenêtre d'un contrôle fait à 22 h.
      if (!a.isCash) continue;
      if (!inRange(a.advanceDate)) continue;
      total += a.amount;
    }
    for (final p in payslips(shopId)) {
      final paidAt = p.paidAt;
      if (paidAt == null || !p.paidCash) continue;
      if (!inRange(paidAt)) continue;
      total += p.netSalary;
    }
    // Heures supplémentaires payées de la main à la main (hotfix_165) : cet
    // argent-là sort du tiroir le soir même, à la fin du service. L'oublier
    // ferait apparaître le montant comme un manquant à la clôture — le faux
    // positif exact qui fait cesser de compter la caisse.
    for (final r in timeRecords(shopId)) {
      if (!r.hasOvertime || !r.overtimeSettled) continue;
      if (r.overtimeSettlement != OvertimeSettlement.paidNow) continue;
      final at = r.clockOut ?? r.createdAt;
      if (!inRange(at)) continue;
      total += r.overtimeAmount;
    }
    // Primes spéciales versées en espèces — même raison.
    total += StaffContestService.cashOut(shopId, from: from, to: to);
    return total;
  }

  /// Masse salariale d'un mois pour le BILAN — le coût du travail, pas
  /// l'argent versé le jour de la paie (cf. `Payslip.laborCost`).
  static int payrollTotal(String shopId, String month) => payslips(shopId,
          month: month)
      .fold(0, (s, p) => s + p.laborCost);

  /// Heures supplémentaires PAYÉES DE LA MAIN À LA MAIN sur un mois.
  ///
  /// Ces heures-là n'entrent JAMAIS dans une fiche de paie, et c'est voulu :
  /// [settleOvertime] les marque soldées à l'instant où le gérant décide de les
  /// payer, ce qui les exclut d'[overtimeToSettle]. Les porter aussi sur la
  /// fiche les paierait deux fois.
  ///
  /// Mais le bilan sommait les fiches. Cet argent, bien sorti du tiroir le soir
  /// même, n'apparaissait donc nulle part en charge : masse salariale
  /// sous-évaluée, bénéfice surévalué d'autant. La clôture de caisse, elle, le
  /// savait déjà — [cashOut] le déduit pour ne pas crier au manquant.
  ///
  /// C'est exactement la maladie des avances, refermée par `Payslip.laborCost`,
  /// et la même décision s'applique : la paie du bilan est le COÛT DU TRAVAIL,
  /// pas l'argent versé le jour de la paie.
  ///
  /// Le mois est celui de la SORTIE, comme partout ailleurs pour les heures
  /// supplémentaires : un service commencé le 31 à 21 h et fini le 1er à 2 h
  /// appartient au mois où il s'est terminé — c'est la nuit qui a été payée,
  /// pas la soirée.
  ///
  /// Fonction pure — la liste est fournie par l'appelant — pour être
  /// vérifiable sans Hive.
  static int overtimePaidInCashFor(List<TimeRecord> records, String month) {
    var total = 0;
    for (final r in records) {
      if (!r.hasOvertime || !r.overtimeSettled) continue;
      if (r.overtimeSettlement != OvertimeSettlement.paidNow) continue;
      final at = r.clockOut ?? r.createdAt;
      if (SalaryAdvance.monthKey(at) != month) continue;
      total += r.overtimeAmount;
    }
    return total;
  }

  /// Idem, lu depuis Hive.
  static int overtimePaidInCash(String shopId, String month) =>
      overtimePaidInCashFor(timeRecords(shopId), month);

  /// Masse salariale ESTIMÉE d'un mois, d'après les CONTRATS.
  ///
  /// Sans fiche de paie, la masse salariale du mois valait zéro : un restaurant
  /// à 300 000 F de salaires affichait, le 18 du mois, un bénéfice surévalué de
  /// 180 000 F — puis le voyait s'effondrer d'un coup le jour où le gérant
  /// générait ses fiches, sans qu'aucune vente n'ait changé. Un salaire non
  /// encore arrêté est dû quand même.
  ///
  /// ELLE NE GÉNÈRE RIEN. [generatePayslip] solde les avances, les heures
  /// supplémentaires et les pénalités : ce sont des écritures irréversibles
  /// qu'un simple affichage n'a pas à déclencher. L'estimation reste en
  /// lecture seule, et la vraie fiche la remplace dès qu'elle existe.
  ///
  /// C'est une APPROXIMATION assumée : elle ignore primes, heures
  /// supplémentaires, absences et retenues, qui ne sont connues qu'à
  /// l'établissement de la fiche. Le chiffre bougera donc à ce moment-là —
  /// vers le haut avec les primes, vers le bas avec les absences.
  ///
  /// LIMITE : `isActive` est l'état d'AUJOURD'HUI, pas un historique. Sur un
  /// mois passé où un employé a depuis quitté la maison, l'estimation le
  /// sous-estime. En pratique les mois passés ont leurs fiches ; l'estimation
  /// sert surtout au mois en cours, où l'effectif est à jour.
  ///
  /// Fonction pure — la liste est fournie par l'appelant — pour être
  /// vérifiable sans Hive.
  static int payrollEstimateFor(List<StaffMember> members, String month) {
    final parts = month.split('-');
    if (parts.length < 2) return 0;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return 0;
    final start = DateTime(y, m);
    final end = DateTime(y, m + 1);
    final inMonth = end.difference(start).inDays;
    if (inMonth <= 0) return 0;

    var total = 0;
    for (final s in members) {
      if (!s.isActive || s.baseSalary <= 0) continue;
      // Embauché après la fin du mois : il n'y était pas.
      if (!s.hireDate.isBefore(end)) continue;
      // PRORATA D'EMBAUCHE : arrivé le 21 d'un mois de 30 jours, il coûte dix
      // jours et non un mois. Arrivé avant le mois, il le coûte en entier.
      if (s.hireDate.isBefore(start)) {
        total += s.baseSalary;
      } else {
        final worked = inMonth - s.hireDate.day + 1;
        total += s.baseSalary * worked ~/ inMonth;
      }
    }
    return total;
  }

  /// Masse salariale du mois : les FICHES si elles existent, l'estimation
  /// contractuelle sinon.
  ///
  /// `estimated` dit lequel des deux, pour que l'écran puisse le signaler : un
  /// bénéfice calculé sur une paie estimée n'a pas le même statut qu'un
  /// bénéfice calculé sur des fiches arrêtées.
  static ({int amount, bool estimated}) payrollOrEstimate(
      String shopId, String month) {
    // Payées de la main à la main, donc hors de toute fiche : elles s'ajoutent
    // aux deux branches, car l'argent est sorti quelle que soit l'avancée de
    // la paie.
    final cash = overtimePaidInCash(shopId, month);
    final real = payrollTotal(shopId, month);
    if (real > 0) return (amount: real + cash, estimated: false);
    return (
      amount: payrollEstimateFor(forShop(shopId), month) + cash,
      estimated: true
    );
  }

  // ── Écriture commune ────────────────────────────────────────────────────

  static Future<void> _put(Box<Map> box, String table, String shopId,
      String id, Map<String, dynamic> map) async {
    try {
      await box.put(id, map);
    } catch (e) {
      debugPrint('[Staff] put $table err: $e');
    }
    AppDatabase.bgUpsert(table, map);
    AppDatabase.notifyListeners(table, shopId);
  }
}
