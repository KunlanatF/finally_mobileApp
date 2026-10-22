import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart'
    show databaseFactoryFfiWeb;

class DBHelper {
  static Database? _db;
  static const int _dbVersion = 4;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await initDB();
    return _db!;
  }

  static Future<Database> initDB() async {
    late final String path;

    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      path = 'grocery_price_web.db';
    } else {
      path = join(await getDatabasesPath(), 'grocery_price.db');
    }
    return await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await _createCategoriesAndSuppliers(db);

    await db.execute('''
      CREATE TABLE products(
        barcode TEXT PRIMARY KEY,
        name TEXT,
        price REAL,
        cost REAL DEFAULT 0,
        stock_qty INTEGER DEFAULT 0,
        min_qty INTEGER DEFAULT 0,
        category_id INTEGER,
        supplier_id INTEGER,
        label_outdated INTEGER DEFAULT 0,
        last_checked TEXT,
        image_file TEXT,
        FOREIGN KEY(category_id) REFERENCES categories(id),
        FOREIGN KEY(supplier_id) REFERENCES suppliers(id)
      )
    ''');

    await _createExtraTables(db);
    await _seedCategories(db);
    await _migrateToV4(db);

    await db.insert('products', {
      'barcode': '8851234567890',
      'name': 'ยาทาแผลสด โพวิโดน-ไอโอดีน (ตราเสือดาว)',
      'price': 15.0,
      'category_id': 1,
    });
    await db.insert('products', {
      'barcode': '8859876543210',
      'name': 'ยาทาแผลสด',
      'price': 20.0,
      'category_id': 1,
    });
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createCategoriesAndSuppliers(db);
      await _seedCategories(db);

      await db.execute('ALTER TABLE products ADD COLUMN cost REAL DEFAULT 0');
      await db.execute(
        'ALTER TABLE products ADD COLUMN stock_qty INTEGER DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE products ADD COLUMN min_qty INTEGER DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE products ADD COLUMN category_id INTEGER REFERENCES categories(id)',
      );
      await db.execute(
        'ALTER TABLE products ADD COLUMN supplier_id INTEGER REFERENCES suppliers(id)',
      );
      await db.execute(
        'ALTER TABLE products ADD COLUMN label_outdated INTEGER DEFAULT 0',
      );
      await db.execute('ALTER TABLE products ADD COLUMN last_checked TEXT');

      await db.execute('UPDATE products SET category_id = 1');

      await _createExtraTables(db);
    }

    if (oldVersion < 3) {
      // เก็บเฉพาะ "ชื่อไฟล์" ของรูปสินค้า (ไฟล์จริงอยู่ในโฟลเดอร์ของแอป)
      await db.execute('ALTER TABLE products ADD COLUMN image_file TEXT');
    }

    if (oldVersion < 4) {
      await _migrateToV4(db);
    }
  }

  /// v4: ระบบแจ้งเตือนสินค้าใกล้หมด/หมด และใกล้หมดอายุ/หมดอายุ
  static Future<void> _migrateToV4(Database db) async {
    // จำนวนวันที่ให้เตือนก่อนหมดอายุ (0 = ไม่เตือนวันหมดอายุของหมวดนี้)
    await db.execute(
      'ALTER TABLE categories ADD COLUMN expiry_alert_days INTEGER DEFAULT 7',
    );

    // หมวด "ยา" เตือนล่วงหน้า 30 วัน
    final med = await db.query(
      'categories',
      where: 'name = ?',
      whereArgs: ['ยา'],
    );
    if (med.isEmpty) {
      await db.insert('categories', {
        'name': 'ยา',
        'check_freq': 'weekly',
        'auto_restock': 0,
        'expiry_alert_days': 30,
      });
    }

    await db.execute('''
      CREATE TABLE notifications(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,        -- low_stock | out_of_stock | expiring | expired
        severity TEXT NOT NULL,    -- warning | critical
        barcode TEXT NOT NULL,
        batch_id INTEGER,
        title TEXT NOT NULL,
        message TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,  -- กันแจ้งซ้ำ เช่น low_stock:<barcode>, expired:<batch_id>
        created_at TEXT NOT NULL,
        read_at TEXT,              -- ผู้ใช้เปิดอ่านแล้ว
        notified_at TEXT,          -- ส่ง notification ขึ้นเครื่องแล้ว
        resolved_at TEXT,          -- เงื่อนไขหายแล้ว (เติมของ/จัดการล็อตแล้ว)
        FOREIGN KEY(barcode) REFERENCES products(barcode) ON DELETE CASCADE,
        FOREIGN KEY(batch_id) REFERENCES batches(id) ON DELETE CASCADE
      )
    ''');

    // ห้ามมีแจ้งเตือนที่ยัง active ซ้ำกัน แต่เกิดใหม่ได้หลัง resolved แล้ว
    await db.execute(
      'CREATE UNIQUE INDEX ux_notifications_active ON notifications(dedupe_key) WHERE resolved_at IS NULL',
    );
    await db.execute(
      'CREATE INDEX idx_notifications_state ON notifications(resolved_at, read_at)',
    );
    await db.execute('CREATE INDEX idx_batches_expiry ON batches(expiry_date)');
  }

  static Future<void> _createCategoriesAndSuppliers(Database db) async {
    await db.execute('''
      CREATE TABLE categories(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        check_freq TEXT DEFAULT 'weekly',
        auto_restock INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE suppliers(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        line_id TEXT
      )
    ''');
  }

  static Future<void> _createExtraTables(Database db) async {
    await db.execute('''
      CREATE TABLE batches(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        barcode TEXT NOT NULL,
        expiry_date TEXT NOT NULL,
        qty INTEGER NOT NULL,
        FOREIGN KEY(barcode) REFERENCES products(barcode) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE price_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        barcode TEXT NOT NULL,
        old_price REAL,
        new_price REAL,
        changed_at TEXT,
        FOREIGN KEY(barcode) REFERENCES products(barcode) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE waste_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        barcode TEXT NOT NULL,
        qty INTEGER NOT NULL,
        reason TEXT,
        cost_lost REAL DEFAULT 0,
        created_at TEXT,
        FOREIGN KEY(barcode) REFERENCES products(barcode) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE customer_requests(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_name TEXT NOT NULL,
        created_at TEXT
      )
    ''');
  }

  static Future<void> _seedCategories(Database db) async {
    await db.insert('categories', {
      'id': 1,
      'name': 'ทั่วไป',
      'check_freq': 'weekly',
      'auto_restock': 0,
    });
    await db.insert('categories', {
      'id': 2,
      'name': 'เบียร์',
      'check_freq': 'weekly',
      'auto_restock': 0,
    });
    await db.insert('categories', {
      'id': 3,
      'name': 'ไอศกรีม',
      'check_freq': 'none',
      'auto_restock': 1,
    });
    await db.insert('categories', {
      'id': 4,
      'name': 'ของใช้ (เช็ครายเดือน)',
      'check_freq': 'monthly',
      'auto_restock': 0,
    });
  }

  static Future<Map<String, dynamic>?> getProduct(String barcode) async {
    final db = await database;
    final result = await db.query(
      'products',
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
    return result.isNotEmpty ? result.first : null;
  }

  static Future<void> insertOrUpdateProduct(
    String barcode,
    String name,
    double price,
  ) async {
    final db = await database;
    final existing = await getProduct(barcode);
    if (existing == null) {
      await db.insert('products', {
        'barcode': barcode,
        'name': name,
        'price': price,
        'category_id': 1,
      });
    } else {
      await updateProduct(barcode, name, price);
    }
  }

  static Future<List<Map<String, dynamic>>> getAllProducts() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT p.*, c.name AS category_name
      FROM products p
      LEFT JOIN categories c ON p.category_id = c.id
      ORDER BY p.name ASC
    ''');
  }

  static Future<int> updateProduct(
    String barcode,
    String name,
    double price,
  ) async {
    final db = await database;
    return await db.transaction((txn) async {
      final rows = await txn.query(
        'products',
        columns: ['price'],
        where: 'barcode = ?',
        whereArgs: [barcode],
      );

      final values = <String, Object?>{'name': name, 'price': price};

      if (rows.isNotEmpty) {
        final oldPrice = (rows.first['price'] as num?)?.toDouble();
        if (oldPrice != price) {
          await txn.insert('price_history', {
            'barcode': barcode,
            'old_price': oldPrice,
            'new_price': price,
            'changed_at': DateTime.now().toIso8601String(),
          });
          values['label_outdated'] = 1;
        }
      }

      return await txn.update(
        'products',
        values,
        where: 'barcode = ?',
        whereArgs: [barcode],
      );
    });
  }

  static Future<int> updateProductImage(
    String barcode,
    String? imageFile,
  ) async {
    final db = await database;
    return await db.update(
      'products',
      {'image_file': imageFile},
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
  }

  static Future<int> deleteProduct(String barcode) async {
    final db = await database;
    return await db.delete(
      'products',
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
  }

  static Future<int> updateStockSettings(
    String barcode, {
    required int stockQty,
    required int minQty,
    required int? categoryId,
  }) async {
    final db = await database;
    final n = await db.update(
      'products',
      {
        'stock_qty': stockQty,
        'min_qty': minQty,
        'category_id': categoryId,
        'last_checked': DateTime.now().toIso8601String(),
      },
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
    await refreshAlerts();
    return n;
  }

  static Future<void> addStock(String barcode, int qty) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE products SET stock_qty = stock_qty + ?, last_checked = ? WHERE barcode = ?',
      [qty, DateTime.now().toIso8601String(), barcode],
    );
    await refreshAlerts();
  }

  static Future<List<Map<String, dynamic>>> getShoppingList() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT p.*, c.name AS category_name,
             s.name AS supplier_name, s.phone AS supplier_phone
      FROM products p
      LEFT JOIN categories c ON p.category_id = c.id
      LEFT JOIN suppliers s ON p.supplier_id = s.id
      WHERE p.min_qty > 0
        AND p.stock_qty <= p.min_qty
        AND COALESCE(c.auto_restock, 0) = 0
      ORDER BY s.name, p.name
    ''');
  }

  static Future<List<Map<String, dynamic>>> getCategories() async {
    final db = await database;
    return await db.query('categories', orderBy: 'id ASC');
  }

  static Future<void> markLabelUpdated(String barcode) async {
    final db = await database;
    await db.update(
      'products',
      {'label_outdated': 0},
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
  }

  static Future<List<Map<String, dynamic>>> getPriceHistory(
    String barcode,
  ) async {
    final db = await database;
    return await db.query(
      'price_history',
      where: 'barcode = ?',
      whereArgs: [barcode],
      orderBy: 'changed_at DESC',
    );
  }

  /// เพิ่มล็อตสินค้า (วันหมดอายุ + จำนวน)
  /// ตั้ง [updateStock] = true ถ้าต้องการให้ stock_qty เพิ่มตามไปด้วย
  /// (ค่าเริ่มต้น false เพื่อไม่ให้นับซ้ำกับที่ UI เรียก addStock อยู่แล้ว)
  static Future<void> addBatch(
    String barcode,
    DateTime expiry,
    int qty, {
    bool updateStock = false,
  }) async {
    final db = await database;
    final d = expiry.toIso8601String().substring(0, 10);
    await db.transaction((txn) async {
      await txn.insert('batches', {
        'barcode': barcode,
        'expiry_date': d,
        'qty': qty,
      });
      if (updateStock) {
        await txn.rawUpdate(
          'UPDATE products SET stock_qty = stock_qty + ?, last_checked = ? WHERE barcode = ?',
          [qty, DateTime.now().toIso8601String(), barcode],
        );
      }
    });
    await refreshAlerts();
  }

  static Future<List<Map<String, dynamic>>> getExpiringBatches(int days) async {
    final db = await database;
    final cutoff = DateTime.now()
        .add(Duration(days: days))
        .toIso8601String()
        .substring(0, 10);
    return await db.rawQuery(
      '''
      SELECT b.*, p.name
      FROM batches b
      JOIN products p ON b.barcode = p.barcode
      WHERE b.expiry_date <= ? AND b.qty > 0
      ORDER BY b.expiry_date ASC
    ''',
      [cutoff],
    );
  }

  /// ล็อตที่ใกล้หมดอายุหรือหมดอายุแล้ว ตามกฎเดียวกับระบบแจ้งเตือน
  /// (จำนวนวันเตือนตามหมวดหมู่ เช่น ยา 30 วัน, หมวดอื่น 7 วัน, 0 = ไม่เตือน)
  static Future<List<Map<String, dynamic>>> getAlertExpiringBatches() async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT b.*, p.name
      FROM batches b
      JOIN products p ON b.barcode = p.barcode
      LEFT JOIN categories c ON p.category_id = c.id
      WHERE b.qty > 0
        AND COALESCE(c.expiry_alert_days, 7) > 0
        AND b.expiry_date <= date(?, '+' || COALESCE(c.expiry_alert_days, 7) || ' days')
      ORDER BY b.expiry_date ASC
    ''',
      [_ymd(DateTime.now())],
    );
  }

  /// ล็อตที่ยังมีของของสินค้านี้ เรียงตามวันหมดอายุ
  static Future<List<Map<String, dynamic>>> getBatchesByBarcode(
    String barcode,
  ) async {
    final db = await database;
    return db.query(
      'batches',
      where: 'barcode = ? AND qty > 0',
      whereArgs: [barcode],
      orderBy: 'expiry_date ASC',
    );
  }

  /// ลบล็อต (แจ้งเตือนของล็อตนั้นจะถูกลบตามด้วย ON DELETE CASCADE)
  static Future<void> deleteBatch(int id) async {
    final db = await database;
    await db.delete('batches', where: 'id = ?', whereArgs: [id]);
    await refreshAlerts();
  }

  static Future<void> addWaste(String barcode, int qty, String reason) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'products',
        columns: ['cost'],
        where: 'barcode = ?',
        whereArgs: [barcode],
      );
      final cost = rows.isNotEmpty
          ? (rows.first['cost'] as num?)?.toDouble() ?? 0.0
          : 0.0;

      await txn.insert('waste_log', {
        'barcode': barcode,
        'qty': qty,
        'reason': reason,
        'cost_lost': cost * qty,
        'created_at': DateTime.now().toIso8601String(),
      });

      await txn.rawUpdate(
        'UPDATE products SET stock_qty = MAX(stock_qty - ?, 0) WHERE barcode = ?',
        [qty, barcode],
      );
    });
    await refreshAlerts();
  }

  static Future<void> addCustomerRequest(String itemName) async {
    final db = await database;
    await db.insert('customer_requests', {
      'item_name': itemName,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getTopCustomerRequests() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT item_name, COUNT(*) AS times
      FROM customer_requests
      GROUP BY item_name
      ORDER BY times DESC
    ''');
  }

  // ================= ระบบแจ้งเตือน =================

  static String _ymd(DateTime d) => d.toIso8601String().substring(0, 10);

  static String _thDate(String ymd) {
    final d = DateTime.parse(ymd);
    return '${d.day}/${d.month}/${d.year + 543}';
  }

  /// คำนวณแจ้งเตือนปัจจุบันใหม่ทั้งหมด
  /// - เพิ่มรายการที่เพิ่งเข้าเงื่อนไข
  /// - อัปเดตข้อความรายการที่ยังอยู่
  /// - ปิด (resolved) รายการที่เงื่อนไขหายไปแล้ว
  /// คืนจำนวนรายการใหม่
  static Future<int> refreshAlerts() async {
    final db = await database;
    final now = DateTime.now();
    final today = _ymd(now);
    final nowIso = now.toIso8601String();

    return db.transaction((txn) async {
      final current = <String, Map<String, Object?>>{};

      void add({
        required String type,
        required String severity,
        required String barcode,
        int? batchId,
        required String key,
        required String title,
        required String message,
      }) {
        current[key] = {
          'type': type,
          'severity': severity,
          'barcode': barcode,
          'batch_id': batchId,
          'dedupe_key': key,
          'title': title,
          'message': message,
        };
      }

      // 1) สินค้าใกล้หมด / หมด (เฉพาะที่ตั้ง min_qty > 0 และไม่ใช่หมวดเติมอัตโนมัติ)
      final stockRows = await txn.rawQuery('''
        SELECT p.barcode, p.name, p.stock_qty, p.min_qty
        FROM products p
        LEFT JOIN categories c ON p.category_id = c.id
        WHERE p.min_qty > 0
          AND p.stock_qty <= p.min_qty
          AND COALESCE(c.auto_restock, 0) = 0
      ''');
      for (final r in stockRows) {
        final barcode = r['barcode'] as String;
        final name = (r['name'] as String?) ?? barcode;
        final stock = (r['stock_qty'] as int?) ?? 0;
        final min = (r['min_qty'] as int?) ?? 0;
        if (stock <= 0) {
          add(
            type: 'out_of_stock',
            severity: 'critical',
            barcode: barcode,
            key: 'out_of_stock:$barcode',
            title: 'สินค้าหมด',
            message: '$name หมดสต็อกแล้ว (ขั้นต่ำ $min)',
          );
        } else {
          add(
            type: 'low_stock',
            severity: 'warning',
            barcode: barcode,
            key: 'low_stock:$barcode',
            title: 'สินค้าใกล้หมด',
            message: '$name เหลือ $stock (ขั้นต่ำ $min)',
          );
        }
      }

      // 2) ล็อตใกล้หมดอายุ / หมดอายุแล้ว
      // (บังคับให้ fallback เป็นอย่างน้อย 7 วัน ถ้าหมวดหมู่ไม่ได้ตั้งค่าไว้ และรวมถึงล็อตที่หมดอายุไปแล้วด้วย)
      final expRows = await txn.rawQuery(
        '''
        SELECT b.id, b.barcode, b.expiry_date, b.qty, p.name,
               c.name AS category_name
        FROM batches b
        JOIN products p ON b.barcode = p.barcode
        LEFT JOIN categories c ON p.category_id = c.id
        WHERE b.qty > 0
          AND b.expiry_date <= date(?, '+' || CASE WHEN COALESCE(c.expiry_alert_days, 0) <= 0 THEN 7 ELSE c.expiry_alert_days END || ' days')
      ''',
        [today],
      );

      for (final r in expRows) {
        final id = r['id'] as int;
        final barcode = r['barcode'] as String;
        final name = (r['name'] as String?) ?? barcode;
        final qty = (r['qty'] as int?) ?? 0;
        final exp = r['expiry_date'] as String;
        final label = r['category_name'] == 'ยา' ? 'ยา' : 'สินค้า';
        final daysLeft = DateTime.parse(
          exp,
        ).difference(DateTime.parse(today)).inDays;

        if (daysLeft < 0) {
          add(
            type: 'expired',
            severity: 'critical',
            barcode: barcode,
            batchId: id,
            key: 'expired:$id',
            title: '$labelหมดอายุแล้ว',
            message: '$name ล็อตหมดอายุ ${_thDate(exp)} (เหลือ $qty)',
          );
        } else {
          final when = daysLeft == 0
              ? 'หมดอายุวันนี้'
              : 'จะหมดอายุในอีก $daysLeft วัน (${_thDate(exp)})';
          add(
            type: 'expiring',
            severity: 'warning',
            barcode: barcode,
            batchId: id,
            key: 'expiring:$id',
            title: '$labelใกล้หมดอายุ',
            message: '$name $when (เหลือ $qty)',
          );
        }
      }

      // 3) เทียบกับรายการ active ในตาราง
      final active = await txn.query(
        'notifications',
        columns: ['id', 'dedupe_key'],
        where: 'resolved_at IS NULL',
      );
      final activeKeys = {
        for (final a in active) a['dedupe_key'] as String: a['id'] as int,
      };

      final batch = txn.batch();
      var created = 0;
      current.forEach((key, v) {
        final existingId = activeKeys[key];
        if (existingId == null) {
          batch.insert('notifications', {...v, 'created_at': nowIso});
          created++;
        } else {
          batch.update(
            'notifications',
            {'title': v['title'], 'message': v['message']},
            where: 'id = ?',
            whereArgs: [existingId],
          );
        }
      });
      activeKeys.forEach((key, id) {
        if (!current.containsKey(key)) {
          batch.update(
            'notifications',
            {'resolved_at': nowIso},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });
      await batch.commit(noResult: true);
      return created;
    });
  }

  /// แจ้งเตือนที่ยัง active เรียงด่วน (critical) ก่อน
  /// [type] = low_stock | out_of_stock | expiring | expired
  static Future<List<Map<String, dynamic>>> getActiveAlerts({
    String? type,
  }) async {
    final db = await database;
    return db.rawQuery('''
      SELECT n.*, p.name AS product_name, p.image_file
      FROM notifications n
      JOIN products p ON n.barcode = p.barcode
      WHERE n.resolved_at IS NULL ${type == null ? '' : 'AND n.type = ?'}
      ORDER BY CASE n.severity WHEN 'critical' THEN 0 ELSE 1 END,
               n.created_at DESC
    ''', type == null ? [] : [type]);
  }

  /// จำนวนแจ้งเตือนที่ยังไม่อ่าน (ใช้ทำ badge)
  static Future<int> getUnreadAlertCount() async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) FROM notifications WHERE resolved_at IS NULL AND read_at IS NULL',
    );
    return (r.first.values.first as int?) ?? 0;
  }

  static Future<void> markAlertRead(int id) async {
    final db = await database;
    await db.update(
      'notifications',
      {'read_at': DateTime.now().toIso8601String()},
      where: 'id = ? AND read_at IS NULL',
      whereArgs: [id],
    );
  }

  static Future<void> markAllAlertsRead() async {
    final db = await database;
    await db.update('notifications', {
      'read_at': DateTime.now().toIso8601String(),
    }, where: 'resolved_at IS NULL AND read_at IS NULL');
  }

  /// รายการที่ยังไม่เคยส่ง notification ขึ้นเครื่อง
  static Future<List<Map<String, dynamic>>> getUnnotifiedAlerts() async {
    final db = await database;
    return db.query(
      'notifications',
      where: 'resolved_at IS NULL AND notified_at IS NULL',
      orderBy: 'id ASC',
    );
  }

  static Future<void> markAlertsNotified(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final nowIso = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final id in ids) {
      batch.update(
        'notifications',
        {'notified_at': nowIso},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// ทิ้งทั้งล็อต (เช่น ยาหมดอายุ): ตัดสต็อก + บันทึก waste_log + ปิดล็อต
  /// แล้วแจ้งเตือนของล็อตนั้นจะถูก resolved อัตโนมัติ
  static Future<void> disposeBatch(
    int batchId, {
    String reason = 'หมดอายุ',
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT b.barcode, b.qty, p.cost
        FROM batches b
        JOIN products p ON b.barcode = p.barcode
        WHERE b.id = ?
      ''',
        [batchId],
      );
      if (rows.isEmpty) return;

      final barcode = rows.first['barcode'] as String;
      final qty = (rows.first['qty'] as int?) ?? 0;
      final cost = (rows.first['cost'] as num?)?.toDouble() ?? 0.0;
      if (qty <= 0) return;

      await txn.insert('waste_log', {
        'barcode': barcode,
        'qty': qty,
        'reason': reason,
        'cost_lost': cost * qty,
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.rawUpdate(
        'UPDATE products SET stock_qty = MAX(stock_qty - ?, 0) WHERE barcode = ?',
        [qty, barcode],
      );
      await txn.update(
        'batches',
        {'qty': 0},
        where: 'id = ?',
        whereArgs: [batchId],
      );
    });
    await refreshAlerts();
  }

  /// สถิติ 4 ช่องบนหน้า Home
  /// keys: total, needBuy, expiring, labels
  static Future<Map<String, int>> getDashboardStats({
    int expiryDays = 7,
  }) async {
    final db = await database;
    final cutoff = DateTime.now()
        .add(Duration(days: expiryDays))
        .toIso8601String()
        .substring(0, 10);

    int first(List<Map<String, Object?>> r) =>
        (r.first.values.first as int?) ?? 0;

    final total = first(await db.rawQuery('SELECT COUNT(*) FROM products'));

    final needBuy = first(
      await db.rawQuery('''
      SELECT COUNT(*) FROM products p
      LEFT JOIN categories c ON p.category_id = c.id
      WHERE p.min_qty > 0
        AND p.stock_qty <= p.min_qty
        AND COALESCE(c.auto_restock, 0) = 0
    '''),
    );

    final expiring = first(
      await db.rawQuery(
        'SELECT COUNT(DISTINCT barcode) FROM batches WHERE qty > 0 AND expiry_date <= ?',
        [cutoff],
      ),
    );

    final labels = first(
      await db.rawQuery(
        'SELECT COUNT(*) FROM products WHERE label_outdated = 1',
      ),
    );

    return {
      'total': total,
      'needBuy': needBuy,
      'expiring': expiring,
      'labels': labels,
    };
  }
}
