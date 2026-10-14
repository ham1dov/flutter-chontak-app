import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const _green = Color(0xFF2ECC71);
const _red = Color(0xFFE74C3C);
const _blue = Color(0xFF3498DB);
const _ink = Color(0xFF20252D);
const _muted = Color(0xFF87909B);
const _paper = Color(0xFFF5F6FA);
const _categories = <String>[
  'Food',
  'Transport',
  'Shopping',
  'Health',
  'Entertainment',
  'Housing',
  'Utilities',
  'Education',
  'Salary',
  'Business',
  'Investment',
  'Other',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
  }
  runApp(const FinanceApp());
}

class FinanceEntry {
  FinanceEntry({
    required this.id,
    required this.amount,
    required this.category,
    required this.isIncome,
    required this.createdAt,
    required this.updatedAt,
    this.note = '',
    this.deleted = false,
  });

  final String id;
  final double amount;
  final String category;
  final bool isIncome;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String note;
  final bool deleted;

  Map<String, dynamic> toJson({String? userId}) => {
        'id': id,
        if (userId != null) 'user_id': userId,
        'amount': amount,
        'category': category,
        'type': isIncome ? 'income' : 'expense',
        'note': note,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'deleted': deleted,
      };

  factory FinanceEntry.fromJson(Map<String, dynamic> json) => FinanceEntry(
        id: json['id'] as String,
        amount: (json['amount'] as num).toDouble(),
        category: json['category'] as String,
        isIncome: json['type'] == 'income',
        note: json['note'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        updatedAt: DateTime.parse(json['updated_at'] as String).toLocal(),
        deleted: json['deleted'] as bool? ?? false,
      );
}

class FinanceStore extends ChangeNotifier {
  static const _entriesKey = 'finance.entries.v1';
  static const _currencyKey = 'finance.currency.v1';
  final _connectivity = Connectivity();
  final _uuid = const Uuid();
  final Map<String, FinanceEntry> _entries = {};
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _syncing = false;
  bool _syncRequested = false;
  bool _online = false;
  String currency = 'UZS';

  bool get syncConfigured => _supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty;
  bool get online => _online;
  bool get syncing => _syncing;
  List<FinanceEntry> get entries => _entries.values
      .where((entry) => !entry.deleted)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    currency = preferences.getString(_currencyKey) ?? 'UZS';
    final saved = preferences.getString(_entriesKey);
    if (saved != null) {
      final list = jsonDecode(saved) as List<dynamic>;
      for (final row in list) {
        final entry = FinanceEntry.fromJson(row as Map<String, dynamic>);
        _entries[entry.id] = entry;
      }
    }
    notifyListeners();
    final results = await _connectivity.checkConnectivity();
    _online = results.any((result) => result != ConnectivityResult.none);
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((results) {
      _online = results.any((result) => result != ConnectivityResult.none);
      notifyListeners();
      if (_online) unawaited(sync());
    });
    if (_online) unawaited(sync());
  }

  Future<void> setCurrency(String value) async {
    currency = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_currencyKey, value);
    notifyListeners();
  }

  Future<void> saveEntry({
    String? id,
    required double amount,
    required String category,
    required bool isIncome,
    required String note,
    required DateTime createdAt,
  }) async {
    final now = DateTime.now();
    final entryId = id ?? _uuid.v4();
    _entries[entryId] = FinanceEntry(
      id: entryId,
      amount: amount,
      category: category,
      isIncome: isIncome,
      note: note,
      createdAt: createdAt,
      updatedAt: now,
    );
    await _persist();
    if (_online) unawaited(sync());
  }

  Future<void> removeEntry(FinanceEntry entry) async {
    _entries[entry.id] = FinanceEntry(
      id: entry.id,
      amount: entry.amount,
      category: entry.category,
      isIncome: entry.isIncome,
      note: entry.note,
      createdAt: entry.createdAt,
      updatedAt: DateTime.now(),
      deleted: true,
    );
    await _persist();
    if (_online) unawaited(sync());
  }

  Future<void> sync() async {
    if (!syncConfigured || !_online) return;
    if (_syncing) {
      _syncRequested = true;
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentSession == null) {
        await client.auth.signInAnonymously();
      }
      final userId = client.auth.currentUser!.id;
      final remote = await client.from('transactions').select();
      var changed = false;
      for (final row in remote) {
        final incoming = FinanceEntry.fromJson(row);
        final local = _entries[incoming.id];
        if (local == null || incoming.updatedAt.isAfter(local.updatedAt)) {
          _entries[incoming.id] = incoming;
          changed = true;
        }
      }
      if (_entries.isNotEmpty) {
        await client.from('transactions').upsert(
              _entries.values.map((entry) => entry.toJson(userId: userId)).toList(),
              onConflict: 'id',
            );
      }
      if (changed) await _persist();
    } catch (_) {
      // Preserve local data; a later connection event retries sync.
    } finally {
      _syncing = false;
      notifyListeners();
      if (_syncRequested) {
        _syncRequested = false;
        unawaited(sync());
      }
    }
  }

  Future<void> _persist() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _entriesKey,
      jsonEncode(_entries.values.map((entry) => entry.toJson()).toList()),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}

class FinanceApp extends StatefulWidget {
  const FinanceApp({super.key});

  @override
  State<FinanceApp> createState() => _FinanceAppState();
}

class _FinanceAppState extends State<FinanceApp> {
  final _store = FinanceStore();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _store,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Finance Tracker',
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: _paper,
            colorScheme: ColorScheme.fromSeed(seedColor: _blue, surface: _paper),
            fontFamily: 'Roboto',
            appBarTheme: const AppBarTheme(
              backgroundColor: _paper,
              foregroundColor: _ink,
              surfaceTintColor: Colors.transparent,
            ),
          ),
          home: _ready ? TrackerShell(store: _store) : const _LoadingScreen(),
        ),
      );
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}

class TrackerShell extends StatefulWidget {
  const TrackerShell({required this.store, super.key});
  final FinanceStore store;

  @override
  State<TrackerShell> createState() => _TrackerShellState();
}

class _TrackerShellState extends State<TrackerShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final titles = ['This month', 'Transactions', 'Statistics', 'Settings'];
    final pages = [
      _OverviewPage(store: widget.store),
      _TransactionsPage(store: widget.store),
      _InsightsPage(store: widget.store),
      _SettingsPage(store: widget.store),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: _SyncIndicator(store: widget.store),
          ),
        ],
      ),
      body: SafeArea(top: false, child: IndexedStack(index: _tab, children: pages)),
      floatingActionButton: _tab < 2
          ? FloatingActionButton(
              onPressed: () => _openEntry(context, widget.store),
              backgroundColor: _blue,
              foregroundColor: Colors.white,
              tooltip: 'Add transaction',
              child: const Icon(Icons.add_rounded, size: 28),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.space_dashboard_outlined), selectedIcon: Icon(Icons.space_dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Activity'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Statistics'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}

class _SyncIndicator extends StatelessWidget {
  const _SyncIndicator({required this.store});
  final FinanceStore store;

  @override
  Widget build(BuildContext context) {
    final text = store.syncing ? 'Syncing' : !store.syncConfigured ? 'Device only' : store.online ? 'Synced' : 'Offline';
    final dot = store.syncing ? _blue : !store.syncConfigured ? _muted : store.online ? _green : _red;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (store.syncing)
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(text, style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.store});
  final FinanceStore store;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monthly = store.entries.where((entry) => entry.createdAt.year == now.year && entry.createdAt.month == now.month);
    final income = monthly.where((entry) => entry.isIncome).fold<double>(0, (sum, entry) => sum + entry.amount);
    final expenses = monthly.where((entry) => !entry.isIncome).fold<double>(0, (sum, entry) => sum + entry.amount);
    final net = income - expenses;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 96),
      children: [
        Text(DateFormat('MMMM yyyy').format(now), style: const TextStyle(color: _muted, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _SummaryCard(title: 'Income', amount: income, color: _green, currency: store.currency)),
            const SizedBox(width: 9),
            Expanded(child: _SummaryCard(title: 'Expense', amount: expenses, color: _red, currency: store.currency)),
            const SizedBox(width: 9),
            Expanded(child: _SummaryCard(title: 'Balance', amount: net, color: _blue, currency: store.currency)),
          ],
        ),
        const SizedBox(height: 24),
        const _SectionHeading(title: '12-month trend', trailing: Text('Income  /  Expense', style: TextStyle(color: _muted, fontSize: 10))),
        const SizedBox(height: 10),
        _TrendPanel(entries: store.entries, currency: store.currency),
        const SizedBox(height: 24),
        _SectionHeading(
          title: 'Recent activity',
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _AllTransactionsPage(store: store))),
            child: const Text('See all'),
          ),
        ),
        const SizedBox(height: 6),
        if (store.entries.isEmpty)
          const _EmptyState(icon: Icons.receipt_long_outlined, title: 'No transactions yet', subtitle: 'Add income or an expense to start your monthly overview.')
        else
          ...store.entries.take(5).map((entry) => _TransactionTile(entry: entry, currency: store.currency)),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.title, required this.amount, required this.color, required this.currency});
  final String title;
  final double amount;
  final Color color;
  final String currency;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 100),
        padding: const EdgeInsets.fromLTRB(11, 13, 8, 11),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 9),
            FittedBox(alignment: Alignment.centerLeft, child: Text(_money(amount, currency), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800))),
          ],
        ),
      );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w700))),
          if (trailing != null) trailing!,
        ],
      );
}

class _TrendPanel extends StatelessWidget {
  const _TrendPanel({required this.entries, required this.currency});
  final List<FinanceEntry> entries;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monthValues = List.generate(12, (index) {
      final month = DateTime(now.year, now.month - 11 + index);
      var income = 0.0;
      var expense = 0.0;
      for (final entry in entries) {
        if (entry.createdAt.year == month.year && entry.createdAt.month == month.month) {
          if (entry.isIncome) {
            income += entry.amount;
          } else {
            expense += entry.amount;
          }
        }
      }
      return (month, income, expense);
    });
    final maxAmount = monthValues.fold<double>(0, (max, value) => value.$2 > value.$3 ? (value.$2 > max ? value.$2 : max) : (value.$3 > max ? value.$3 : max));
    final top = maxAmount == 0 ? 10.0 : maxAmount * 1.2;
    return Container(
      height: 204,
      padding: const EdgeInsets.fromLTRB(10, 18, 18, 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9)),
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: top,
          gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: top / 4, getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFFE9EDF2), strokeWidth: 1)),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36, interval: top / 4, getTitlesWidget: (value, _) => Text(_compactMoney(value), style: const TextStyle(color: _muted, fontSize: 9)))),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 2, getTitlesWidget: (value, _) {
              final index = value.toInt();
              if (index < 0 || index >= monthValues.length || index.isOdd) return const SizedBox.shrink();
              return Padding(padding: const EdgeInsets.only(top: 7), child: Text(DateFormat('MMM').format(monthValues[index].$1), style: const TextStyle(color: _muted, fontSize: 9)));
            })),
          ),
          lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(getTooltipItems: (spots) => spots.map((spot) => LineTooltipItem(_money(spot.y, currency), TextStyle(color: spot.bar.color, fontWeight: FontWeight.w600))).toList())),
          lineBarsData: [
            _line(monthValues.map((value) => value.$2).toList(), _green),
            _line(monthValues.map((value) => value.$3).toList(), _red),
          ],
        ),
      ),
    );
  }

  LineChartBarData _line(List<double> values, Color color) => LineChartBarData(
        spots: List.generate(values.length, (index) => FlSpot(index.toDouble(), values[index])),
        color: color,
        barWidth: 2.5,
        isCurved: true,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.08)),
      );
}

class _TransactionsPage extends StatefulWidget {
  const _TransactionsPage({required this.store});
  final FinanceStore store;

  @override
  State<_TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<_TransactionsPage> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final entries = widget.store.entries.where((entry) => _filter == 'all' || entry.isIncome == (_filter == 'income')).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All'), icon: Icon(Icons.swap_vert_rounded)),
              ButtonSegment(value: 'expense', label: Text('Expenses'), icon: Icon(Icons.south_east_rounded)),
              ButtonSegment(value: 'income', label: Text('Income'), icon: Icon(Icons.north_east_rounded)),
            ],
            selected: {_filter},
            onSelectionChanged: (selected) => setState(() => _filter = selected.first),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const _EmptyState(icon: Icons.receipt_long_outlined, title: 'Nothing to show', subtitle: 'Your transactions will appear here.')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 90),
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _TransactionTile(
                    entry: entries[index],
                    currency: widget.store.currency,
                    onTap: () => _openEntry(context, widget.store, existing: entries[index]),
                    onDelete: () => widget.store.removeEntry(entries[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _AllTransactionsPage extends StatelessWidget {
  const _AllTransactionsPage({required this.store});
  final FinanceStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('All transactions')),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: store.entries.isEmpty
              ? const [_EmptyState(icon: Icons.receipt_long_outlined, title: 'No transactions yet', subtitle: 'New activity will appear here.')]
              : store.entries.map((entry) => _TransactionTile(entry: entry, currency: store.currency)).toList(),
        ),
      );
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.entry, required this.currency, this.onTap, this.onDelete});
  final FinanceEntry entry;
  final String currency;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final color = entry.isIncome ? _green : _red;
    return Dismissible(
      key: ValueKey(entry.id),
      direction: onDelete == null ? DismissDirection.none : DismissDirection.endToStart,
      onDismissed: (_) => onDelete?.call(),
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.only(right: 18),
        decoration: BoxDecoration(color: _red, borderRadius: BorderRadius.circular(8)),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Icon(_categoryIcon(entry.category), color: color, size: 21),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.category, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ink, fontWeight: FontWeight.w700, fontSize: 14)),
                      const SizedBox(height: 3),
                      Text(entry.note.isEmpty ? DateFormat('d MMM, HH:mm').format(entry.createdAt) : '${entry.note}  ·  ${DateFormat('d MMM').format(entry.createdAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 11)),
                    ],
                  ),
                ),
                Text('${entry.isIncome ? '+' : '-'}${_money(entry.amount, currency)}', style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InsightsPage extends StatefulWidget {
  const _InsightsPage({required this.store});
  final FinanceStore store;

  @override
  State<_InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<_InsightsPage> {
  bool _expenses = true;
  DateTimeRange _range = DateTimeRange(start: DateTime(DateTime.now().year, DateTime.now().month, 1), end: DateTime.now());

  @override
  Widget build(BuildContext context) {
    final filtered = widget.store.entries.where((entry) {
      final date = DateTime(entry.createdAt.year, entry.createdAt.month, entry.createdAt.day);
      final start = DateTime(_range.start.year, _range.start.month, _range.start.day);
      final end = DateTime(_range.end.year, _range.end.month, _range.end.day, 23, 59, 59);
      return entry.isIncome != _expenses && !date.isBefore(start) && !date.isAfter(end);
    }).toList();
    final totals = <String, double>{};
    for (final entry in filtered) {
      totals.update(entry.category, (value) => value + entry.amount, ifAbsent: () => entry.amount);
    }
    final sorted = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = sorted.fold<double>(0, (sum, row) => sum + row.value);
    final colors = [_blue, _green, const Color(0xFFF39C12), const Color(0xFF8E9AAF), const Color(0xFF16A085), const Color(0xFFE67E22), const Color(0xFF7F8C8D)];
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 5, 18, 30),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Expenses'), icon: Icon(Icons.south_east_rounded)),
            ButtonSegment(value: false, label: Text('Income'), icon: Icon(Icons.north_east_rounded)),
          ],
          selected: {_expenses},
          onSelectionChanged: (selected) => setState(() => _expenses = selected.first),
        ),
        const SizedBox(height: 13),
        OutlinedButton.icon(
          onPressed: () async {
            final selected = await showDateRangePicker(context: context, firstDate: DateTime(2018), lastDate: DateTime.now(), initialDateRange: _range);
            if (selected != null) setState(() => _range = selected);
          },
          icon: const Icon(Icons.calendar_month_outlined, size: 18),
          label: Text('${DateFormat('d MMM').format(_range.start)}  –  ${DateFormat('d MMM yyyy').format(_range.end)}'),
        ),
        const SizedBox(height: 18),
        if (sorted.isEmpty)
          const _EmptyState(icon: Icons.pie_chart_outline, title: 'No data for this period', subtitle: 'Try another date range or add a transaction.')
        else ...[
          Container(
            height: 224,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9)),
            child: Row(
              children: [
                Expanded(
                  child: PieChart(PieChartData(
                    centerSpaceRadius: 48,
                    sectionsSpace: 2,
                    sections: List.generate(sorted.length, (index) {
                      final amount = sorted[index].value;
                      return PieChartSectionData(
                        color: colors[index % colors.length],
                        value: amount,
                        radius: 54,
                        title: total == 0 ? '' : '${(amount / total * 100).round()}%',
                        titleStyle: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                      );
                    }),
                  )),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_expenses ? 'Total expenses' : 'Total income', style: const TextStyle(color: _muted, fontSize: 12)),
                      const SizedBox(height: 4),
                      FittedBox(alignment: Alignment.centerLeft, child: Text(_money(total, widget.store.currency), style: const TextStyle(color: _ink, fontSize: 20, fontWeight: FontWeight.w800))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 17),
          ...List.generate(sorted.length, (index) {
            final row = sorted[index];
            final color = colors[index % colors.length];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: Row(children: [Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)), const SizedBox(width: 10), Expanded(child: Text(row.key, style: const TextStyle(color: _ink, fontWeight: FontWeight.w600))), Text(_money(row.value, widget.store.currency), style: const TextStyle(color: _ink, fontWeight: FontWeight.w700))]),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.store});
  final FinanceStore store;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const _SectionHeading(title: 'Preferences'),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: store.currency,
                isExpanded: true,
                borderRadius: BorderRadius.circular(8),
                items: const ['UZS', 'USD', 'EUR', 'RUB'].map((currency) => DropdownMenuItem(value: currency, child: Text('Currency  ·  $currency'))).toList(),
                onChanged: (value) {
                  if (value != null) store.setCurrency(value);
                },
              ),
            ),
          ),
          const SizedBox(height: 25),
          const _SectionHeading(title: 'Data and sync'),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [Icon(store.syncConfigured ? Icons.cloud_done_outlined : Icons.phone_android, color: store.syncConfigured ? _green : _blue), const SizedBox(width: 10), Expanded(child: Text(store.syncConfigured ? 'Private device sync' : 'Stored on this device', style: const TextStyle(color: _ink, fontWeight: FontWeight.w700)))]),
                const SizedBox(height: 8),
                Text(
                  store.syncConfigured
                      ? 'Changes are saved here first and synced when you are online. Your anonymous device profile has no sign-in or recovery option.'
                      : 'Your records are saved locally and work offline. Connect a Supabase project at build time to enable cloud sync. Removing app data or changing devices will not transfer local-only records.',
                  style: const TextStyle(color: _muted, height: 1.45, fontSize: 12),
                ),
                if (store.syncConfigured) ...[
                  const SizedBox(height: 13),
                  OutlinedButton.icon(onPressed: store.online ? store.sync : null, icon: const Icon(Icons.sync, size: 18), label: const Text('Sync now')),
                ],
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text('Finance Tracker  ·  1.0.0', textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 11)),
        ],
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xFFBBC2CB), size: 34),
            const SizedBox(height: 9),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: _ink, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 12, height: 1.4)),
          ],
        ),
      );
}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({this.existing});
  final FinanceEntry? existing;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late final TextEditingController _customCategory;
  late bool _income;
  late String _category;
  late DateTime _date;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final entry = widget.existing;
    _amount = TextEditingController(text: entry == null ? '' : entry.amount.toStringAsFixed(entry.amount % 1 == 0 ? 0 : 2));
    _note = TextEditingController(text: entry?.note ?? '');
    _customCategory = TextEditingController(text: entry != null && !_categories.contains(entry.category) ? entry.category : '');
    _income = entry?.isIncome ?? false;
    _category = entry?.category ?? 'Food';
    _date = entry?.createdAt ?? DateTime.now();
    if (!_categories.contains(_category)) _category = 'Other';
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _customCategory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: 20, right: 20, top: 12, bottom: MediaQuery.viewInsetsOf(context).bottom + 22),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: const Color(0xFFDDE1E6), borderRadius: BorderRadius.circular(4)))),
                const SizedBox(height: 18),
                Text(widget.existing == null ? 'New transaction' : 'Edit transaction', style: const TextStyle(color: _ink, fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Income'), icon: Icon(Icons.north_east_rounded)),
                    ButtonSegment(value: false, label: Text('Expense'), icon: Icon(Icons.south_east_rounded)),
                  ],
                  selected: {_income},
                  onSelectionChanged: (values) => setState(() => _income = values.first),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount', prefixIcon: Icon(Icons.payments_outlined), border: OutlineInputBorder()),
                  validator: (value) {
                    final amount = double.tryParse((value ?? '').replaceAll(',', '.'));
                    return amount == null || amount <= 0 ? 'Enter an amount greater than zero' : null;
                  },
                ),
                const SizedBox(height: 15),
                DropdownButtonFormField<String>(
                  value: _category,
                  decoration: const InputDecoration(labelText: 'Category', prefixIcon: Icon(Icons.category_outlined), border: OutlineInputBorder()),
                  items: _categories.map((category) => DropdownMenuItem(value: category, child: Text(category))).toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _category = value);
                  },
                ),
                if (_category == 'Other') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _customCategory,
                    decoration: const InputDecoration(labelText: 'Custom category', prefixIcon: Icon(Icons.edit_outlined), border: OutlineInputBorder()),
                  ),
                ],
                const SizedBox(height: 15),
                TextFormField(controller: _note, maxLength: 160, decoration: const InputDecoration(labelText: 'Note (optional)', prefixIcon: Icon(Icons.notes_rounded), border: OutlineInputBorder())),
                const SizedBox(height: 2),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined, color: _muted),
                  title: const Text('Date', style: TextStyle(fontSize: 13, color: _muted)),
                  subtitle: Text(DateFormat('EEE, d MMM yyyy').format(_date), style: const TextStyle(color: _ink, fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final selected = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2018), lastDate: DateTime.now());
                    if (selected != null) setState(() => _date = DateTime(selected.year, selected.month, selected.day, _date.hour, _date.minute));
                  },
                ),
                const SizedBox(height: 13),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (!_formKey.currentState!.validate()) return;
                      Navigator.of(context).pop((
                        amount: double.parse(_amount.text.replaceAll(',', '.')),
                        category: _category == 'Other' && _customCategory.text.trim().isNotEmpty ? _customCategory.text.trim() : _category,
                        income: _income,
                        note: _note.text.trim(),
                        date: _date,
                      ));
                    },
                    child: Text(widget.existing == null ? 'Save transaction' : 'Update transaction'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

Future<void> _openEntry(BuildContext context, FinanceStore store, {FinanceEntry? existing}) async {
  final result = await showModalBottomSheet<({double amount, String category, bool income, String note, DateTime date})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
    builder: (_) => _EntryEditor(existing: existing),
  );
  if (result != null) {
    await store.saveEntry(
      id: existing?.id,
      amount: result.amount,
      category: result.category,
      isIncome: result.income,
      note: result.note,
      createdAt: result.date,
    );
  }
}

IconData _categoryIcon(String category) => switch (category.toLowerCase()) {
      'food' => Icons.restaurant_outlined,
      'transport' => Icons.directions_bus_outlined,
      'shopping' => Icons.shopping_bag_outlined,
      'health' => Icons.medical_services_outlined,
      'entertainment' => Icons.movie_outlined,
      'housing' => Icons.home_outlined,
      'utilities' => Icons.lightbulb_outline,
      'education' => Icons.school_outlined,
      'salary' => Icons.work_outline,
      'business' => Icons.storefront_outlined,
      'investment' => Icons.trending_up_rounded,
      _ => Icons.more_horiz_rounded,
    };

String _money(double amount, String currency) => '${NumberFormat('#,##0.##').format(amount)} $currency';

String _compactMoney(double amount) => NumberFormat.compact().format(amount);