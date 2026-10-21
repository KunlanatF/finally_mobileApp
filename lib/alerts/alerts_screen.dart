import 'package:flutter/material.dart';
import '../helper/db_helper.dart';
import '../product/product_edit_sheet.dart';

enum _Filter { all, stock, expiry }

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    await DBHelper.refreshAlerts();
    return DBHelper.getActiveAlerts();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  bool _matches(Map<String, dynamic> a) {
    final type = a['type'] as String;
    return switch (_filter) {
      _Filter.all => true,
      _Filter.stock => type == 'low_stock' || type == 'out_of_stock',
      _Filter.expiry => type == 'expiring' || type == 'expired',
    };
  }

  String _filterLabel(_Filter f) => switch (f) {
    _Filter.all => 'ทั้งหมด',
    _Filter.stock => 'สต็อก',
    _Filter.expiry => 'วันหมดอายุ',
  };

  IconData _icon(String type) => switch (type) {
    'out_of_stock' => Icons.remove_shopping_cart_outlined,
    'low_stock' => Icons.shopping_cart_outlined,
    'expired' => Icons.event_busy_outlined,
    _ => Icons.hourglass_bottom_outlined,
  };

  Future<void> _markAllRead() async {
    await DBHelper.markAllAlertsRead();
    if (!mounted) return;
    _reload();
  }

  Future<void> _openProduct(Map<String, dynamic> a) async {
    await DBHelper.markAlertRead(a['id'] as int);
    final product = await DBHelper.getProduct(a['barcode'] as String);
    if (!mounted) return;
    if (product != null) {
      await showProductEditSheet(context, product);
      if (!mounted) return;
    }
    _reload();
  }

  Future<void> _disposeBatch(Map<String, dynamic> a) async {
    final batchId = a['batch_id'] as int?;
    if (batchId == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ทิ้งล็อตนี้?'),
        content: Text('${a['message']}\n\nระบบจะตัดสต็อกและบันทึกเป็นของเสีย'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ทิ้งล็อต'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await DBHelper.disposeBatch(batchId);
    if (!mounted) return;
    _reload();
  }

  Widget _tile(Map<String, dynamic> a, ColorScheme cs) {
    final type = a['type'] as String;
    final critical = a['severity'] == 'critical';
    final unread = a['read_at'] == null;
    final color = critical ? cs.error : cs.tertiary;

    Widget? trailing;
    if (type == 'expired' && a['batch_id'] != null) {
      trailing = IconButton(
        tooltip: 'ทิ้งล็อตนี้',
        icon: const Icon(Icons.delete_sweep_outlined),
        onPressed: () => _disposeBatch(a),
      );
    } else if (unread) {
      trailing = Icon(Icons.circle, size: 10, color: cs.primary);
    }

    return ListTile(
      onTap: () => _openProduct(a),
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.12),
        child: Icon(_icon(type), color: color),
      ),
      title: Text(
        a['title'] as String,
        style: TextStyle(
          fontWeight: unread ? FontWeight.bold : FontWeight.w500,
        ),
      ),
      subtitle: Text(a['message'] as String),
      trailing: trailing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('การแจ้งเตือน'),
        actions: [
          IconButton(
            onPressed: _markAllRead,
            tooltip: 'ทำเครื่องหมายว่าอ่านแล้วทั้งหมด',
            icon: const Icon(Icons.done_all),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  for (final f in _Filter.values)
                    ChoiceChip(
                      label: Text(_filterLabel(f)),
                      selected: _filter == f,
                      onSelected: (_) {
                        if (mounted) {
                          setState(() => _filter = f);
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'โหลดข้อมูลไม่สำเร็จ\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  );
                }

                final items = (snapshot.data ?? []).where(_matches).toList();

                return RefreshIndicator(
                  onRefresh: () async {
                    _reload();
                    await _future;
                  },
                  child: items.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 120),
                            Icon(
                              Icons.check_circle_outline,
                              size: 48,
                              color: cs.primary,
                            ),
                            const SizedBox(height: 12),
                            const Center(child: Text('ไม่มีแจ้งเตือน')),
                          ],
                        )
                      : ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) => _tile(items[i], cs),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
