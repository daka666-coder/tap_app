import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kApiBase = '把你的AppsScript WebApp URL貼這裡'; // 例如 https://script.google.com/macros/s/xxx/exec
const String kApiKey = 'tapapp-123';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_TW', null);
  Intl.defaultLocale = 'zh_TW';
  runApp(const TapApp());
}

class TapApp extends StatelessWidget {
  const TapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tap App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF3B200)),
      ),
      home: const ClockPage(),
    );
  }
}

class Employee {
  final String empId;
  final String name;
  const Employee({required this.empId, required this.name});

  factory Employee.fromJson(Map<String, dynamic> j) =>
      Employee(empId: '${j['empId']}', name: '${j['name'] ?? ''}');
}

class Shift {
  final String shiftId;
  final String start; // HH:mm
  final String end;   // HH:mm
  final int graceInMin;
  final int graceOutMin;

  const Shift({
    required this.shiftId,
    required this.start,
    required this.end,
    required this.graceInMin,
    required this.graceOutMin,
  });

  factory Shift.fromJson(Map<String, dynamic> j) => Shift(
        shiftId: '${j['shiftId']}',
        start: '${j['start']}',
        end: '${j['end']}',
        graceInMin: (j['graceInMin'] ?? 0) as int,
        graceOutMin: (j['graceOutMin'] ?? 0) as int,
      );
}

class RosterRow {
  final String date;  // yyyy-MM-dd
  final String empId;
  final String shiftId;

  const RosterRow({required this.date, required this.empId, required this.shiftId});

  factory RosterRow.fromJson(Map<String, dynamic> j) => RosterRow(
        date: '${j['date']}',
        empId: '${j['empId']}',
        shiftId: '${j['shiftId']}',
      );
}

class ClockPage extends StatefulWidget {
  const ClockPage({super.key});

  @override
  State<ClockPage> createState() => _ClockPageState();
}

class _ClockPageState extends State<ClockPage> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  bool _loading = true;
  String? _error;

  List<Employee> _employees = [];
  List<Shift> _shifts = [];
  List<RosterRow> _rosterToday = [];

  String? _selectedEmpId;
  DateTime? _firstPunch;
  DateTime? _lastPunch;

  String get _todayKey => DateFormat('yyyy-MM-dd').format(_now);

  String _firstKey(String empId, String date) => 'punch:$empId:$date:first';
  String _lastKey(String empId, String date) => 'punch:$empId:$date:last';

  Employee? get _selectedEmployee =>
      _employees.where((e) => e.empId == _selectedEmpId).cast<Employee?>().firstOrNull;

  RosterRow? get _selectedRoster =>
      _rosterToday.where((r) => r.empId == _selectedEmpId).cast<RosterRow?>().firstOrNull;

  Shift? get _selectedShift {
    final shiftId = _selectedRoster?.shiftId;
    if (shiftId == null) return null;
    return _shifts.where((s) => s.shiftId == shiftId).cast<Shift?>().firstOrNull;
  }

  @override
  void initState() {
    super.initState();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      await _fetchConfig();
      await _fetchRosterToday();

      final prefs = await SharedPreferences.getInstance();
      final savedEmp = prefs.getString('selectedEmpId');

      // 預設：如果有今日排班，就選第一個有排班的人；不然選員工清單第一個
      String? defaultEmp;
      if (_rosterToday.isNotEmpty) defaultEmp = _rosterToday.first.empId;
      if (defaultEmp == null && _employees.isNotEmpty) defaultEmp = _employees.first.empId;

      _selectedEmpId = (savedEmp != null && _employees.any((e) => e.empId == savedEmp))
          ? savedEmp
          : defaultEmp;

      if (_selectedEmpId != null) {
        await _loadTodayPunch();
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '載入失敗：$e';
      });
    }
  }

  Future<void> _fetchConfig() async {
    final uri = Uri.parse('$kApiBase?action=config&key=$kApiKey');
    final res = await http.get(uri);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['ok'] != true) throw body['error'] ?? 'config error';

    final employees = (body['employees'] as List).map((e) => Employee.fromJson(e)).toList();
    final shifts = (body['shifts'] as List).map((s) => Shift.fromJson(s)).toList();

    _employees = employees;
    _shifts = shifts;
  }

  Future<void> _fetchRosterToday() async {
    final uri = Uri.parse('$kApiBase?action=roster&date=$_todayKey&key=$kApiKey');
    final res = await http.get(uri);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['ok'] != true) throw body['error'] ?? 'roster error';

    _rosterToday = (body['roster'] as List).map((r) => RosterRow.fromJson(r)).toList();
  }

  Future<void> _loadTodayPunch() async {
    final empId = _selectedEmpId;
    if (empId == null) return;

    final prefs = await SharedPreferences.getInstance();
    final first = prefs.getString(_firstKey(empId, _todayKey));
    final last = prefs.getString(_lastKey(empId, _todayKey));

    setState(() {
      _firstPunch = first != null ? DateTime.parse(first) : null;
      _lastPunch = last != null ? DateTime.parse(last) : null;
    });
  }

  Future<void> _switchEmployee(String empId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selectedEmpId', empId);

    setState(() {
      _selectedEmpId = empId;
      _firstPunch = null;
      _lastPunch = null;
    });

    await _loadTodayPunch();
  }

  Future<void> _punch() async {
    final empId = _selectedEmpId;
    if (empId == null) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    // local store
    if (_firstPunch == null) {
      await prefs.setString(_firstKey(empId, _todayKey), now.toIso8601String());
      _firstPunch = now;
    }
    await prefs.setString(_lastKey(empId, _todayKey), now.toIso8601String());
    _lastPunch = now;

    setState(() {});

    // write back to sheet
    final employee = _selectedEmployee;
    final roster = _selectedRoster;
    final shiftId = roster?.shiftId ?? '';

    // 第一次視為 IN，之後每次視為 OUT（簡化版；你要 IN/OUT 分開按鈕也可以做）
    final action = (_firstPunch == now) ? 'IN' : 'OUT';

    final payload = {
      "action": "punch",
      "key": kApiKey,
      "ts": now.toIso8601String(),
      "date": _todayKey,
      "empId": empId,
      "name": employee?.name ?? '',
      "shiftId": shiftId,
      "action": action,
    };

    // 不讓寫入失敗影響 UI（寫入錯也不當場讓你崩潰）
    try {
      await http.post(
        Uri.parse(kApiBase),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateText = DateFormat('yyyy/MM/dd').format(_now);
    final weekdayText = DateFormat('EEEE').format(_now);
    final timeText = DateFormat('HH:mm').format(_now);

    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF3B200),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFFF3B200),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _bootstrap,
                  child: const Text('重新載入'),
                )
              ],
            ),
          ),
        ),
      );
    }

    final emp = _selectedEmployee;
    final shift = _selectedShift;
    final shiftText = shift == null ? '（今日未排班）' : '${shift.shiftId}  ${shift.start}–${shift.end}';

    return Scaffold(
      backgroundColor: const Color(0xFFF3B200),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 日期/星期 + 員工下拉
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(dateText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  Row(
                    children: [
                      Text(weekdayText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 16),
                      _empDropdown(),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 時間
              Text(timeText, style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold)),

              const SizedBox(height: 8),

              // 員工 + 班別
              Text(
                '員工：${emp?.name ?? '--'}（${_selectedEmpId ?? '--'}）',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                '班別：$shiftText',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),

              const SizedBox(height: 24),

              // 打卡資訊卡
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7E6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    _infoRow(icon: Icons.login, title: '首次打卡', time: _firstPunch),
                    const Divider(),
                    _infoRow(icon: Icons.logout, title: '最後打卡', time: _lastPunch),
                  ],
                ),
              ),

              const Spacer(),

              // 打卡按鈕（保留）
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: (_selectedEmpId == null) ? null : _punch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text(
                    '打卡',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empDropdown() {
    // 只顯示「今日有排班的人」會比較貼近你的需求；若你要顯示全部員工也可以改
    final rosterEmpIds = _rosterToday.map((r) => r.empId).toSet();
    final list = _employees.where((e) => rosterEmpIds.contains(e.empId)).toList();
    final items = list.isNotEmpty ? list : _employees;

    // 沒資料時保底
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final current = (_selectedEmpId != null && items.any((e) => e.empId == _selectedEmpId))
        ? _selectedEmpId
        : items.first.empId;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          items: items
              .map((e) => DropdownMenuItem<String>(
                    value: e.empId,
                    child: Text('${e.name}（${e.empId}）'),
                  ))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            _switchEmployee(v);
          },
        ),
      ),
    );
  }

  Widget _infoRow({required IconData icon, required String title, DateTime? time}) {
    return Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
        Text(
          time != null ? DateFormat('HH:mm').format(time) : '--:--',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

extension FirstOrNullExt<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
