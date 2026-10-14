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
}