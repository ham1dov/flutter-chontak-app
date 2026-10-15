import 'package:finance_tracker_mobile/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transaction records round-trip through the shared sync format', () {
    final entry = FinanceEntry(
      id: '6b761e98-46c9-4c73-931d-dd3a4d90d89d',
      amount: 1250.5,
      category: 'Custom category',
      isIncome: false,
      note: 'Monthly payment',
      createdAt: DateTime(2026, 10, 14, 12, 30),
      updatedAt: DateTime(2026, 10, 14, 12, 35),
      deleted: true,
    );

    final restored = FinanceEntry.fromJson(entry.toJson());

    expect(restored.id, entry.id);
    expect(restored.amount, entry.amount);
    expect(restored.category, entry.category);
    expect(restored.isIncome, entry.isIncome);
    expect(restored.note, entry.note);
    expect(restored.createdAt, entry.createdAt);
    expect(restored.updatedAt, entry.updatedAt);
    expect(restored.deleted, isTrue);
  });

  group('mergeEntries', () {
    FinanceEntry make(String id, DateTime updatedAt, {String note = '', bool deleted = false}) => FinanceEntry(
          id: id,
          amount: 10,
          category: 'Food',
          isIncome: false,
          note: note,
          createdAt: DateTime(2026, 10, 1),
          updatedAt: updatedAt,
          deleted: deleted,
        );

    test('adds records that exist only on the other side', () {
      final local = {'a': make('a', DateTime(2026, 10, 1))};
      final changed = mergeEntries(local, [make('b', DateTime(2026, 10, 2))]);

      expect(changed, isTrue);
      expect(local.keys, unorderedEquals(['a', 'b']));
    });

    test('keeps the most recently updated version and never drops local-only records', () {
      final local = {
        'a': make('a', DateTime(2026, 10, 5), note: 'local newer'),
        'b': make('b', DateTime(2026, 10, 1), note: 'cloud newer'),
        'offline': make('offline', DateTime(2026, 10, 6)),
      };
      final changed = mergeEntries(local, [
        make('a', DateTime(2026, 10, 3), note: 'cloud older'),
        make('b', DateTime(2026, 10, 4), note: 'cloud newer wins'),
      ]);

      expect(changed, isTrue);
      expect(local['a']!.note, 'local newer');
      expect(local['b']!.note, 'cloud newer wins');
      expect(local.containsKey('offline'), isTrue);
    });

    test('propagates deletions and reports no change for identical data', () {
      final local = {'a': make('a', DateTime(2026, 10, 1))};
      expect(mergeEntries(local, [make('a', DateTime(2026, 10, 2), deleted: true)]), isTrue);
      expect(local['a']!.deleted, isTrue);
      expect(mergeEntries(local, [make('a', DateTime(2026, 10, 2), deleted: true)]), isFalse);
    });
  });
}
