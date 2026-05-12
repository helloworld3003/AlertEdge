import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static const _databaseName = "AlertEdgeLog.db";
  static const _databaseVersion = 1;

  static const table = 'alert_logs';

  static const columnId = '_id';
  static const columnTimestamp = 'timestamp';
  static const columnStatus = 'status';

  // Make this a singleton class
  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static Database? _database;
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, _databaseName);
    return await openDatabase(path,
        version: _databaseVersion, onCreate: _onCreate);
  }

  Future _onCreate(Database db, int version) async {
    await db.execute('''
          CREATE TABLE $table (
            $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
            $columnTimestamp TEXT NOT NULL,
            $columnStatus TEXT NOT NULL
          )
          ''');
  }

  Future<int> insertLog(String status) async {
    Database db = await instance.database;
    Map<String, dynamic> row = {
      columnTimestamp: DateTime.now().toIso8601String(),
      columnStatus: status,
    };
    return await db.insert(table, row);
  }

  Future<List<Map<String, dynamic>>> queryAllLogs() async {
    Database db = await instance.database;
    return await db.query(table, orderBy: "$columnTimestamp DESC");
  }
}
