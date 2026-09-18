import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/payslip.dart';
import '../../features/restaurant/domain/entities/salary_advance.dart';
import '../../features/restaurant/domain/entities/staff_member.dart';
import '../../features/restaurant/domain/entities/time_record.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

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
  /// En cas de PIN identique entre deux employés (4 chiffres, collisions
  /// possibles), le PREMIER par ordre alphabétique gagne — d'où l'avertissement
  /// à la saisie côté UI.
  static StaffMember? findByPin(String shopId, String pin) {
    if (!isValidPin(pin)) return null;
    for (final s in forShop(shopId, onlyActive: true)) {
      if (!s.hasPin) continue;
      if (hashPin(pin, s.pinSalt!) == s.pinHash) return s;
    }
    return null;
  }

  /// Un autre employé actif utilise-t-il déjà ce code ?
  static bool isPinTaken(String shopId, String pin, {String? exceptId}) {
    final found = findByPin(shopId, pin);
    return found != null && found.id != exceptId;
  }

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

  /// Badge : ouvre un service s'il n'y en a pas, le ferme sinon.
  ///
  /// Retourne le pointage résultant et le sens du badge — l'écran annonce
  /// « Bonjour » ou « Bonne fin de service » à partir de là.
  static Future<({TimeRecord record, bool isEntry})> punch(
    StaffMember member, {
    String method = 'pin',
  }) async {
    final open = openRecord(member.shopId, member.id);
    if (open != null) {
      final end = DateTime.now();
      final closed = open.copyWith(
        clockOut: end,
        durationMinutes:
            TimeRecord.minutesBetween(open.clockIn ?? open.createdAt, end),
      );
      await _put(_timeBox(), 'time_records', closed.shopId, closed.id,
          closed.toMap());
      return (record: closed, isEntry: false);
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
    );
    await _put(_timeBox(), 'time_records', rec.shopId, rec.id, rec.toMap());
    return (record: rec, isEntry: true);
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
      createdAt: DateTime.now(),
    );
    await _put(_advanceBox(), 'salary_advances', a.shopId, a.id, a.toMap());
    return a;
  }

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
  /// Marque les avances du mois comme RETENUES : sans ça, elles seraient
  /// déduites une seconde fois le mois suivant.
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
      netSalary: Payslip.computeNet(
        baseSalary: member.baseSalary,
        bonuses: bonuses,
        deductions: deductions,
        advances: advancesTotal,
      ),
      createdAt: DateTime.now(),
    );
    await _put(_payrollBox(), 'payroll', shopId, slip.id, slip.toMap());

    for (final a in pending) {
      await saveAdvance(a.copyWith(isDeducted: true));
    }
    return slip;
  }

  /// Marque une fiche comme payée.
  static Future<Payslip> markPaid(Payslip slip) async {
    final paid = slip.copyWith(paidAt: DateTime.now());
    await _put(_payrollBox(), 'payroll', paid.shopId, paid.id, paid.toMap());
    return paid;
  }

  /// Supprime une fiche et REND les avances qu'elle avait retenues — sinon
  /// elles resteraient marquées « déduites » sans qu'aucune fiche ne les
  /// porte, et l'employé les perdrait.
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
    return total;
  }

  /// Masse salariale nette d'un mois — alimente le bilan (Lot E).
  static int payrollTotal(String shopId, String month) => payslips(shopId,
          month: month)
      .fold(0, (s, p) => s + p.netSalary);

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
    final real = payrollTotal(shopId, month);
    if (real > 0) return (amount: real, estimated: false);
    return (
      amount: payrollEstimateFor(forShop(shopId), month),
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
