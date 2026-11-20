import 'dart:convert';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:test/test.dart';

void main() {
  final today = DateTime(2026, 11, 19);

  group('writtenDate', () {
    // The owner's vault opens study sessions with dates like these.
    test('a bold weekday, month and day at the start of the title', () {
      expect(writtenDate('**Thu Nov 5** · [[C5 Notes|C5]] · Study (70 min)', today), '2026-11-05');
      expect(writtenDate('**Wed Sep 30** · Read pp. 52–67', today), '2026-09-30');
      expect(writtenDate('__Thu Nov 26__ - Review', today), '2026-11-26');
    });

    test('plain, full and punctuated spellings', () {
      expect(writtenDate('Thu Nov 5 study', today), '2026-11-05');
      expect(writtenDate('Thursday, November 5th: study', today), '2026-11-05');
      expect(writtenDate('Thu. Nov. 5 — study', today), '2026-11-05');
      expect(writtenDate('thu nov 5', today), '2026-11-05');
      expect(writtenDate('Thurs Sept 3', DateTime(2026, 8, 1)), '2026-09-03');
    });

    test('the weekday picks the year nearest today', () {
      expect(writtenDate('**Thu Dec 31** wrap up', DateTime(2027, 1, 2)), '2026-12-31');
      expect(writtenDate('**Wed Dec 3** plan', today), '2025-12-03');
      expect(writtenDate('**Fri Nov 5** plan', today), '2027-11-05');
    });

    test('a written year needs no weekday but must agree with one', () {
      expect(writtenDate('Nov 5, 2026: study', today), '2026-11-05');
      expect(writtenDate('**Thu Nov 5 2026** study', today), '2026-11-05');
      expect(writtenDate('**Fri Nov 5 2026** study', today), isNull);
    });

    test('anything less certain is left alone', () {
      expect(writtenDate('Nov 5 study', today), isNull, reason: 'no weekday or year');
      expect(writtenDate('**Mon Nov 5** study', today), isNull, reason: 'no nearby year has it on a Monday');
      expect(writtenDate('Study on Thu Nov 5', today), isNull, reason: 'not at the start');
      expect(writtenDate('**Thu Nov 31** study', today), isNull, reason: 'no such day');
      expect(writtenDate('Thu Nov 5abc', today), isNull);
      expect(writtenDate('Thu Novel 5', today), isNull);
      expect(writtenDate('Marching Thu Nov 5', today), isNull);
    });

    test('a short number after the day is not a year', () {
      expect(writtenDate('Sat Nov 14, 26 people', today), '2026-11-14');
      expect(writtenDate('Nov 14, 26 people', today), isNull);
    });
  });

  group('Vault written dates', () {
    late Directory root;
    late Vault vault;
    setUp(() {
      root = Directory.systemTemp.createTempSync('facet-written-');
      vault = Vault(root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    const before = '# Plan\n'
        '- [ ] **Wed Sep 30** · [[🔐 C1 Notes|C1]] · Study ✅ C1 done\n'
        '- [ ] **Thu Nov 5** · Read pp. 461–474 🆔 abc123 ^c5\n'
        '- [x] **Thu Oct 29** · Finished ✅ 2026-10-29\n'
        '- [ ] **Thu Nov 26** · Already dated 📅 2026-11-27\n'
        '- [ ] Study on Thu Nov 5\n'
        '- [ ] **Fri Nov 6** · Last one\n';
    const after = '# Plan\n'
        '- [ ] **Wed Sep 30** · [[🔐 C1 Notes|C1]] · Study ✅ C1 done 📅 2026-09-30\n'
        '- [ ] **Thu Nov 5** · Read pp. 461–474 📅 2026-11-05 🆔 abc123 ^c5\n'
        '- [x] **Thu Oct 29** · Finished ✅ 2026-10-29\n'
        '- [ ] **Thu Nov 26** · Already dated 📅 2026-11-27\n'
        '- [ ] Study on Thu Nov 5\n'
        '- [ ] **Fri Nov 6** · Last one 📅 2026-11-06\n';

    test('previews open undated tasks, then adds only their 📅', () {
      final note = File('${root.path}/Plan.md')..writeAsStringSync(before);
      final picks = vault.writtenDates(today);
      expect([for (final p in picks) (p.task.task.line, p.date)],
          [(2, '2026-09-30'), (3, '2026-11-05'), (7, '2026-11-06')]);
      expect(note.readAsStringSync(), before, reason: 'the preview writes nothing');

      final added = vault.addWrittenDates(picks);
      expect(note.readAsBytesSync(), utf8.encode(after));
      expect([for (final t in added) t.task.due], ['2026-09-30', '2026-11-05', '2026-11-06']);
      expect(vault.writtenDates(today), isEmpty);
    });

    test('a note edited after the preview is not touched', () {
      final note = File('${root.path}/Plan.md')..writeAsStringSync(before);
      final picks = vault.writtenDates(today);
      const edited = '$before- [ ] New line\n';
      note.writeAsStringSync(edited);
      expect(() => vault.addWrittenDates(picks), throwsA(isA<VaultConflict>()));
      expect(note.readAsStringSync(), edited);
    });
  });
}
