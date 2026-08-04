import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ✅ 你的 Apps Script Web App URL（你提供的新網址）
const String kApiUrl =
    'https://script.google.com/macros/s/AKfycbxlIn937AiI5m92HM1y9DzIvBsAfisFGDinLkTh3wAe0noKBUqfCRjbIgW3a5HLbb12/exec';

/// ✅ 版本號（右下角顯示用）
/// ✅ 本版修正：
/// 1) firstPunch 顯示「當日第一筆」(以今日日期為準)；不再因時區/登入造成跨日錯置
/// 2) 雲端回傳 ISO 時間（含 Z/offset）一律轉為本機時區顯示
/// 3) 例外申請可指定「補上班卡／補下班卡」與補打卡時間
const String kAppVersion = 'v2026.08.03+exceptionMakeupPunchTime';

/// ✅ 取得定位逾時秒數
const int kGpsTimeoutSec = 15;

/// ✅ 正式定位精準度門檻（公尺）
const double kProdMaxAcceptableAccuracyM = 500;

/// ✅ 主色調（優雅藍）
const Color kPrimaryBlue = Color(0xFF1976D2);

/// ✅ 成功狀態色（與主色調協調的青綠色）
const Color kSuccessGreen = Color(0xFF00A896);

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
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: kPrimaryBlue, // #1976D2
        brightness: Brightness.light,
      ),
    );

    return MaterialApp(
      title: 'Tap App',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFE3F2FD),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.black87,
          elevation: 0,
        ),
        // ✅ 這裡一定要用 CardThemeData
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: kPrimaryBlue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const ClockPage(),
    );
  }
}

/* ----------------------------- Models ----------------------------- */

class Employee {
  final String empId;
  final String empName;
  final String pin;

  Employee({required this.empId, required this.empName, required this.pin});

  factory Employee.fromJson(Map<String, dynamic> j) => Employee(
        empId: '${j['empId']}'.trim(),
        empName: '${j['empName']}'.trim(),
        pin: '${j['pin'] ?? ''}'.trim(),
      );
}

class Shift {
  final String shiftId;
  final String start; // "08:00"
  final String end; // "17:00"
  final int graceInMin;
  final int graceOutMin;

  Shift({
    required this.shiftId,
    required this.start,
    required this.end,
    required this.graceInMin,
    required this.graceOutMin,
  });

  factory Shift.fromJson(Map<String, dynamic> j) => Shift(
        shiftId: '${j['shiftId']}'.trim(),
        start: '${j['start']}'.trim(),
        end: '${j['end']}'.trim(),
        graceInMin: _toInt(j['graceInMin']),
        graceOutMin: _toInt(j['graceOutMin']),
      );
}

class RosterRow {
  final String date; // "yyyy-MM-dd"
  final String empId;
  final String shiftId;

  RosterRow({required this.date, required this.empId, required this.shiftId});

  factory RosterRow.fromJson(Map<String, dynamic> j) => RosterRow(
        date: '${j['date']}'.trim(),
        empId: '${j['empId']}'.trim(),
        shiftId: '${j['shiftId']}'.trim(),
      );
}

/// ✅ 多點圍欄點（GeoFence_Points）
class GeoPoint {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radiusM;

  GeoPoint({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusM,
  });

  factory GeoPoint.fromJson(Map<String, dynamic> j) => GeoPoint(
        id: '${j['id']}'.trim(),
        name: '${j['name']}'.trim(),
        lat: _toDouble(j['lat']),
        lng: _toDouble(j['lng']),
        radiusM: _toDouble(j['radiusM'], def: 300),
      );
}

class GeoEval {
  final bool allowed;
  final GeoPoint? match;
  final double? matchDistanceM;

  final GeoPoint? nearest;
  final double? nearestDistanceM;

  GeoEval({
    required this.allowed,
    required this.match,
    required this.matchDistanceM,
    required this.nearest,
    required this.nearestDistanceM,
  });
}

int _toInt(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toInt();
  return int.tryParse('$v'.trim()) ?? 0;
}

double _toDouble(dynamic v, {double def = 0}) {
  if (v == null) return def;
  if (v is num) return v.toDouble();
  return double.tryParse('$v'.trim()) ?? def;
}

String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
String _hm(DateTime d) => DateFormat('HH:mm').format(d);

/// ✅ 專門處理雲端/本機「時間」：
/// - 支援 ISO 字串（含 Z / +08:00 等）
/// - 支援毫秒 epoch
/// - 一律轉成「本機時區」避免顯示成 UTC 而跨日
DateTime? _parseToLocalDateTime(dynamic v) {
  if (v == null) return null;

  if (v is int) {
    return DateTime.fromMillisecondsSinceEpoch(v, isUtc: false);
  }
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: false);
  }

  final s = '$v'.trim();
  if (s.isEmpty) return null;

  // 嘗試 ISO parse
  final dt = DateTime.tryParse(s);
  if (dt == null) return null;

  return dt.toLocal();
}

bool _isSameLocalYmd(DateTime a, DateTime b) => _ymd(a) == _ymd(b);

/* ----------------------------- Page ----------------------------- */

class ClockPage extends StatefulWidget {
  const ClockPage({super.key});

  @override
  State<ClockPage> createState() => _ClockPageState();
}

class _ClockPageState extends State<ClockPage> {
  final _nowTicker =
      Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now());
  DateTime _now = DateTime.now();

  // Data
  List<Employee> _employees = [];
  List<Shift> _shifts = [];
  List<RosterRow> _roster = [];
  List<GeoPoint> _geoPoints = [];

  // selection (登入後鎖定)
  String? _selectedEmpId;

  // today punch
  DateTime? _firstPunch;
  DateTime? _lastPunch;

  String? _error;
  bool _loading = true;

  // ✅ 登入記錄（本機）
  static const String _kLoginEmpIdKey = 'login:empId';
  static const String _kLoginPinKey = 'login:pin';

  // ✅ 地理圍欄狀態（UI 顯示）
  GeoEval? _lastEval;
  Position? _lastGps;
  DateTime? _lastGpsTime;

  // ✅ 例外申請：無法取得正確位置
  bool _locationException = false;
  String _exceptionPunchType = 'CLOCK_IN';
  DateTime? _exceptionPunchAt;
  final TextEditingController _exceptionReasonCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _exceptionReasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      await _fetchSheetData();

      final loggedIn = await _loadLoggedInEmpId();
      final savedPin = await _loadSavedPin();

      if (loggedIn != null) {
        final exists = _employees.any((e) => e.empId == loggedIn);
        if (exists) {
          _selectedEmpId = loggedIn;

          if (savedPin == null || savedPin.isEmpty) {
            await _clearLoginOnly();
            _selectedEmpId = null;
            _firstPunch = null;
            _lastPunch = null;
          } else {
            await _loadTodayPunch();
            await _checkRejectedExceptionNotice(empId: loggedIn, pin: savedPin);
          }
        } else {
          await _clearLoginOnly();
          _selectedEmpId = null;
          _firstPunch = null;
          _lastPunch = null;
        }
      } else {
        _selectedEmpId = null;
        _firstPunch = null;
        _lastPunch = null;
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '載入失敗：$e';
      });
      debugPrint('❌ Bootstrap 錯誤：$e');
    }
  }

  /* ----------------------------- Fetch Data ----------------------------- */

  /// ✅ GET: /exec?action=data 取得 employees/shifts/roster/geofencePoints
  Future<void> _fetchSheetData() async {
    if (kApiUrl.trim().isEmpty) throw 'kApiUrl 未設定';

    final uri = Uri.parse('$kApiUrl?action=data');

    final resp = await http.get(uri).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('請求逾時（30秒）'),
    );

    if (resp.statusCode != 200) {
      throw 'HTTP ${resp.statusCode}：${resp.reasonPhrase ?? ''}';
    }

    final text = utf8.decode(resp.bodyBytes);

    if (text.trimLeft().startsWith('<')) {
      throw '回傳是 HTML 頁面，可能是權限設定錯誤。\n\n請確認 Apps Script：\n1) 任何人可存取\n2) 已授權\n3) 重新部署並使用新的 URL';
    }
    if (!text.trimLeft().startsWith('{')) {
      throw '回傳不是 JSON。\n內容開頭：${text.substring(0, text.length > 200 ? 200 : text.length)}';
    }

    final Map<String, dynamic> jsonMap = json.decode(text);
    if (jsonMap['ok'] == false) {
      throw 'API 錯誤：${jsonMap['error'] ?? '未知錯誤'}';
    }

    final employeesJson = (jsonMap['employees'] as List?) ?? [];
    final shiftsJson = (jsonMap['shifts'] as List?) ?? [];
    final rosterJson = (jsonMap['roster'] as List?) ?? [];
    final geosJson = (jsonMap['geofencePoints'] as List?) ?? [];

    final employees = employeesJson
        .map((e) => Employee.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final shifts = shiftsJson
        .map((s) => Shift.fromJson(Map<String, dynamic>.from(s)))
        .toList();
    final roster = rosterJson
        .map((r) => RosterRow.fromJson(Map<String, dynamic>.from(r)))
        .toList();
    final geoPoints = geosJson
        .map((g) => GeoPoint.fromJson(Map<String, dynamic>.from(g)))
        .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
        .toList();

    setState(() {
      _employees = employees;
      _shifts = shifts;
      _roster = roster;
      _geoPoints = geoPoints;
    });
  }

  /* ----------------------------- Login ----------------------------- */

  Future<String?> _loadLoggedInEmpId() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kLoginEmpIdKey);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<String?> _loadSavedPin() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kLoginPinKey);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<void> _saveLogin(String empId, String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLoginEmpIdKey, empId.trim());
    await prefs.setString(_kLoginPinKey, pin.trim());
  }

  Future<void> _clearLoginOnly() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLoginEmpIdKey);
    await prefs.remove(_kLoginPinKey);
  }

  Future<void> _logout() async {
    await _clearLoginOnly();

    setState(() {
      _selectedEmpId = null;
      _firstPunch = null;
      _lastPunch = null;
      _lastEval = null;
      _lastGps = null;
      _lastGpsTime = null;
      _error = null;
      _locationException = false;
      _exceptionPunchType = 'CLOCK_IN';
      _exceptionPunchAt = null;
      _exceptionReasonCtrl.text = '';
    });

    await _bootstrap();
  }

  /// ✅ 螢幕正中央的短暫彈出訊息，取代容易被按鈕遮住的 SnackBar
  void _showCenterPopup({
    required IconData icon,
    required Color color,
    required String message,
  }) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black26,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.black12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 38),
                ),
                const SizedBox(height: 14),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black.withOpacity(0.85),
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// ✅ 統一的警示／失敗回饋，取代原本的 _error 底部訊息框與 SnackBar
  void _showWarningPopup(String message) {
    _showCenterPopup(
      icon: Icons.warning_amber_rounded,
      color: Colors.orange,
      message: message,
    );
  }

  Future<void> _showLoginDialog() async {
    final empIdCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    String? localError;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('員工登入'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: empIdCtrl,
                    decoration: const InputDecoration(
                      labelText: '員工編號（empId）',
                      hintText: '例如：E001',
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pinCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '驗證碼（PIN）',
                      hintText: '請輸入驗證碼',
                    ),
                  ),
                  if (localError != null) ...[
                    const SizedBox(height: 10),
                    Text(localError!,
                        style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final empId = empIdCtrl.text.trim();
                    final pin = pinCtrl.text.trim();

                    if (empId.isEmpty) {
                      setLocal(() => localError = '請輸入員工編號');
                      return;
                    }
                    if (pin.isEmpty) {
                      setLocal(() => localError = '請輸入驗證碼（PIN）');
                      return;
                    }

                    final emp = _employees.firstWhere(
                      (e) => e.empId == empId,
                      orElse: () => Employee(empId: '', empName: '', pin: ''),
                    );
                    if (emp.empId.isEmpty) {
                      setLocal(() => localError = '查無此員工編號，請確認輸入');
                      return;
                    }
                    if (emp.pin.trim().isEmpty) {
                      setLocal(() => localError = '此員工尚未設定驗證碼，請洽管理者');
                      return;
                    }
                    if (emp.pin.trim() != pin) {
                      setLocal(() => localError = '驗證碼錯誤，請重新輸入');
                      return;
                    }

                    await _saveLogin(empId, pin);
                    setState(() => _selectedEmpId = empId);

                    await _loadTodayPunch();

                    if (ctx.mounted) Navigator.of(ctx).pop();

                    await _checkRejectedExceptionNotice(empId: empId, pin: pin);
                  },
                  child: const Text('登入'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// ✅ 查詢：補打卡申請是否被主管拒絕（且員工尚未看過），若有則跳出訊息並標記已讀
  Future<void> _checkRejectedExceptionNotice({
    required String empId,
    required String pin,
  }) async {
    if (kApiUrl.trim().isEmpty) return;

    try {
      final uri = Uri.parse(
          '$kApiUrl?action=myExceptionStatus&empId=${Uri.encodeComponent(empId)}&pin=${Uri.encodeComponent(pin)}');

      final resp = await http.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return;

      final text = utf8.decode(resp.bodyBytes);
      if (!text.trimLeft().startsWith('{')) return;

      final j = jsonDecode(text);
      if (j is! Map || j['ok'] != true) return;

      final data = j['data'];
      if (data is! Map) return;

      final requestId = (data['requestId'] ?? '').toString();
      if (requestId.isEmpty) return;

      final dateKey = (data['date'] ?? '').toString();
      final rejectReason = (data['rejectReason'] ?? '').toString().trim();

      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('補打卡申請未通過'),
          content: Text(
            '您於 $dateKey 的補打卡申請已被主管拒絕。'
            '${rejectReason.isNotEmpty ? '\n\n拒絕原因：$rejectReason' : ''}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );

      // 標記已讀，避免下次登入重複跳出
      await http
          .post(
            Uri.parse(kApiUrl),
            headers: {'Content-Type': 'text/plain; charset=utf-8'},
            body: jsonEncode({
              'action': 'ackException',
              'requestId': requestId,
              'empId': empId,
              'pin': pin,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('❌ 查詢補打卡拒絕通知失敗：$e');
    }
  }

  /* ----------------------------- Punch Local + Cloud ----------------------------- */

  String _punchKey(String empId, String ymd) => 'punch:$empId:$ymd';

  /// ✅ 讀取今日打卡：優先雲端（dayPunch），其次本機
  /// ✅ 本版重點：雲端時間一律 toLocal 且必須是「今日」才採用，避免跨日顯示錯置
  Future<void> _loadTodayPunch() async {
    final empId = _selectedEmpId;
    if (empId == null) return;

    final today = DateTime.now();

    // 1) 先回抓雲端
    try {
      final uri = Uri.parse(
          '$kApiUrl?action=dayPunch&empId=${Uri.encodeComponent(empId)}&date=${Uri.encodeComponent(_ymd(today))}');

      final resp = await http.get(uri).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final text = utf8.decode(resp.bodyBytes);
        if (text.trimLeft().startsWith('{')) {
          final Map<String, dynamic> j = json.decode(text);
          if (j['ok'] == true) {
            final cloudFirst = _parseToLocalDateTime(j['firstPunch']);
            final cloudLast = _parseToLocalDateTime(j['lastPunch']);

            // ✅ 僅接受「同一天」的資料（以本機時區判斷）
            DateTime? fp = cloudFirst;
            DateTime? lp = cloudLast;

            if (fp != null && !_isSameLocalYmd(fp, today)) fp = null;
            if (lp != null && !_isSameLocalYmd(lp, today)) lp = null;

            // 若後端回傳有值但跨日，一律視為無資料（避免顯示非當日）
            setState(() {
              _firstPunch = fp;
              _lastPunch = lp;
            });

            if (fp != null || lp != null) {
              // ✅ 存成 epoch，避免下次讀取仍被時區搞亂
              await _saveTodayPunch(
                first: fp ?? lp ?? today,
                last: lp ?? fp ?? today,
              );
            }
            return;
          }
        }
      }
    } catch (_) {
      // 雲端失敗就回本機
    }

    // 2) 回本機
    final prefs = await SharedPreferences.getInstance();
    final key = _punchKey(empId, _ymd(today));
    final raw = prefs.getString(key);

    if (raw == null || raw.isEmpty) {
      setState(() {
        _firstPunch = null;
        _lastPunch = null;
      });
      return;
    }

    try {
      final Map<String, dynamic> j = json.decode(raw);

      // ✅ 新格式：epoch(ms)
      DateTime? fp = _parseToLocalDateTime(j['firstMs']);
      DateTime? lp = _parseToLocalDateTime(j['lastMs']);

      // ✅ 舊格式相容：ISO string
      fp ??= _parseToLocalDateTime(j['first']);
      lp ??= _parseToLocalDateTime(j['last']);

      // ✅ 仍要確保是今日（避免舊資料被誤用）
      if (fp != null && !_isSameLocalYmd(fp, today)) fp = null;
      if (lp != null && !_isSameLocalYmd(lp, today)) lp = null;

      setState(() {
        _firstPunch = fp;
        _lastPunch = lp;
      });
    } catch (_) {
      // ignore
    }
  }

  /// ✅ 儲存今日打卡：以 epoch(ms) 為準，避免 ISO + Z 造成顯示成 UTC
  Future<void> _saveTodayPunch({required DateTime first, required DateTime last}) async {
    final empId = _selectedEmpId!;
    final prefs = await SharedPreferences.getInstance();
    final key = _punchKey(empId, _ymd(DateTime.now()));

    final raw = json.encode({
      'firstMs': first.toLocal().millisecondsSinceEpoch,
      'lastMs': last.toLocal().millisecondsSinceEpoch,
    });

    await prefs.setString(key, raw);
  }

  /* ----------------------------- Geofence ----------------------------- */

  Future<void> _ensureGpsReadyOrThrow() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw '定位服務未開啟（請先在手機設定開啟定位）';
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw '定位權限被拒絕（請允許定位後再打卡）';
    }

    if (permission == LocationPermission.deniedForever) {
      throw '定位權限被永久拒絕（請到系統設定中開啟定位權限）';
    }
  }

  Future<Position> _getCurrentPosition() async {
    await _ensureGpsReadyOrThrow();
    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: kGpsTimeoutSec),
    );
  }

  bool _isAccuracyBad(double? accuracyM) {
    return accuracyM == null ||
        accuracyM <= 0 ||
        accuracyM > kProdMaxAcceptableAccuracyM;
  }

  Future<GeoEval> _evalGeoFence(Position gps) async {
    if (_geoPoints.isEmpty) {
      // 沒設定點：不擋（避免測試卡死）
      return GeoEval(
        allowed: true,
        match: null,
        matchDistanceM: null,
        nearest: null,
        nearestDistanceM: null,
      );
    }

    GeoPoint? nearest;
    double? nearestD;

    GeoPoint? match;
    double? matchD;

    for (final p in _geoPoints) {
      final d = Geolocator.distanceBetween(
        gps.latitude,
        gps.longitude,
        p.lat,
        p.lng,
      );

      if (nearestD == null || d < nearestD) {
        nearestD = d;
        nearest = p;
      }

      if (d <= p.radiusM) {
        if (matchD == null || d < matchD) {
          matchD = d;
          match = p;
        }
      }
    }

    return GeoEval(
      allowed: match != null,
      match: match,
      matchDistanceM: matchD,
      nearest: nearest,
      nearestDistanceM: nearestD,
    );
  }

  /* ----------------------------- Exception Request ----------------------------- */

  Future<bool> _confirmExceptionReasonOrWarn() async {
    if (!_locationException) return true;

    final reason = _exceptionReasonCtrl.text.trim();
    if (reason.isEmpty) {
      _showWarningPopup('已勾選「補打卡」，請務必填寫原因後再送出簽核。');
      return false;
    }

    final requested = _exceptionPunchAt;
    if (requested == null) {
      _showWarningPopup('請選擇要補打卡的日期時間。');
      return false;
    }

    final now = DateTime.now();
    if (requested.isAfter(now.add(const Duration(minutes: 1)))) {
      _showWarningPopup('補打卡時間不能設定為未來時間。');
      return false;
    }

    // ✅ 只有「當日」才有本機已知的首/末筆打卡資料可比對；其他日期由主管簽核時人工確認。
    final sameDayFirst =
        (_firstPunch != null && _isSameLocalYmd(_firstPunch!, requested))
            ? _firstPunch
            : null;
    final sameDayLast =
        (_lastPunch != null && _isSameLocalYmd(_lastPunch!, requested))
            ? _lastPunch
            : null;
    if (_exceptionPunchType == 'CLOCK_IN' &&
        sameDayLast != null &&
        requested.isAfter(sameDayLast)) {
      _showWarningPopup('補上班卡時間不能晚於當日已有的下班卡時間。');
      return false;
    }
    if (_exceptionPunchType == 'CLOCK_OUT' &&
        sameDayFirst != null &&
        requested.isBefore(sameDayFirst)) {
      _showWarningPopup('補下班卡時間不能早於當日已有的上班卡時間。');
      return false;
    }
    return true;
  }

  Future<void> _pickExceptionPunchTime() async {
    final now = DateTime.now();
    final initial = _exceptionPunchAt ?? now;

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
      helpText: '選擇補打卡日期',
      cancelText: '取消',
      confirmText: '下一步',
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: '選擇補打卡時間',
      cancelText: '取消',
      confirmText: '確定',
    );
    if (pickedTime == null || !mounted) return;

    setState(() {
      _exceptionPunchAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  /* ----------------------------- Punch Flow ----------------------------- */

  Future<void> _doPunch() async {
    if (_selectedEmpId == null) {
      _showWarningPopup('請先登入後再打卡');
      return;
    }

    final savedPin = await _loadSavedPin();
    if (savedPin == null || savedPin.isEmpty) {
      _showWarningPopup('登入資訊缺少驗證碼，請先登出後重新登入');
      return;
    }

    // ✅ 若勾選例外：原因必填
    if (!await _confirmExceptionReasonOrWarn()) return;

    setState(() => _error = null);

    final now = DateTime.now();
    // ✅ firstPunch 永遠以「今日第一筆」為準：若今日已有 firstPunch，就沿用；否則用 now
    final first = (_firstPunch != null && _isSameLocalYmd(_firstPunch!, now))
        ? _firstPunch!
        : now;
    final last = now;

    try {
      // ✅ 例外：不走 GPS/圍欄，直接送主管簽核
      if (_locationException) {
        final emp = _currentEmployee;
        final requested = _exceptionPunchAt!;
        final todayFirst = (_firstPunch != null && _isSameLocalYmd(_firstPunch!, requested))
            ? _firstPunch
            : null;
        final todayLast = (_lastPunch != null && _isSameLocalYmd(_lastPunch!, requested))
            ? _lastPunch
            : null;
        final requestFirst = _exceptionPunchType == 'CLOCK_IN'
            ? requested
            : (todayFirst ?? requested);
        final requestLast = _exceptionPunchType == 'CLOCK_OUT'
            ? requested
            : (todayLast ?? requested);

        if (emp == null) throw '找不到員工資料，請重新登入';
        await _postExceptionRequest(
          empId: emp.empId,
          empName: emp.empName,
          pin: savedPin,
          first: requestFirst,
          last: requestLast,
          punchType: _exceptionPunchType,
          requestedPunchAt: requested,
          reason: _exceptionReasonCtrl.text.trim(),
        );

        if (mounted) {
          final typeText = _exceptionPunchType == 'CLOCK_IN' ? '補上班卡' : '補下班卡';
          _showCenterPopup(
            icon: Icons.mark_email_read_rounded,
            color: kPrimaryBlue,
            message: '已送出主管簽核：$typeText\n${_ymd(requested)} ${_hm(requested)}',
          );
          setState(() {
            _locationException = false;
            _exceptionPunchType = 'CLOCK_IN';
            _exceptionPunchAt = null;
            _exceptionReasonCtrl.text = '';
          });
        }
        // ✅ 送出後再回抓一次雲端，確保畫面與雲端一致
        await _loadTodayPunch();
        return;
      }

      // ✅ 正常流程：GPS → 精準度 → 圍欄 → 上傳
      final gps = await _getCurrentPosition();

      final eval = await _evalGeoFence(gps);
      setState(() {
        _lastGps = gps;
        _lastGpsTime = DateTime.now();
        _lastEval = eval;
      });

      if (_isAccuracyBad(gps.accuracy)) {
        _showWarningPopup(
          '定位誤差過大：±${gps.accuracy.toStringAsFixed(0)}m（門檻 ${kProdMaxAcceptableAccuracyM.toStringAsFixed(0)}m）',
        );
        return;
      }

      if (!eval.allowed) {
        final nearestName = eval.nearest?.name ?? '最近點';
        final nearestDist = eval.nearestDistanceM ?? 0;
        final nearestRadius = eval.nearest?.radiusM ?? 0;

        _showWarningPopup(
          '不在允許範圍：距離「$nearestName」約 ${nearestDist.toStringAsFixed(0)}m（允許 ${nearestRadius.toStringAsFixed(0)}m）',
        );
        return;
      }

      await _saveTodayPunch(first: first, last: last);
      setState(() {
        _firstPunch = first;
        _lastPunch = last;
      });

      final emp = _currentEmployee;
      if (emp != null) {
        await _postPunch(
          empId: emp.empId,
          empName: emp.empName,
          pin: savedPin,
          first: first,
          last: last,
          gps: gps,
        );
      }

      final okName = eval.match?.name ?? '打卡點';
      final okDist = eval.matchDistanceM ?? 0;

      if (mounted) {
        _showCenterPopup(
          icon: Icons.check_circle,
          color: kSuccessGreen,
          message: '打卡成功：${_hm(now)}\n（$okName / ${okDist.toStringAsFixed(0)}m）',
        );
      }

      // ✅ 打完卡再回抓一次雲端，保證 first/last 為「雲端認定的當日第一筆/最新一筆」
      await _loadTodayPunch();
    } catch (e) {
      debugPrint('❌ 打卡失敗：$e');
      _showWarningPopup('打卡失敗：$e');
    }
  }

  Employee? get _currentEmployee {
    final id = _selectedEmpId;
    if (id == null) return null;
    for (final e in _employees) {
      if (e.empId == id) return e;
    }
    return null;
  }

  Shift? get _todayShift {
    final empId = _selectedEmpId;
    if (empId == null) return null;

    final today = _ymd(DateTime.now());
    RosterRow? row;
    for (final r in _roster) {
      if (r.empId == empId && r.date == today) {
        row = r;
        break;
      }
    }
    if (row == null) return null;

    for (final s in _shifts) {
      if (s.shiftId == row.shiftId) return s;
    }
    return null;
  }

  /// ✅ POST：正常打卡（需 GPS）
  Future<void> _postPunch({
    required String empId,
    required String empName,
    required String pin,
    required DateTime first,
    required DateTime last,
    required Position gps,
  }) async {
    final uri = Uri.parse(kApiUrl);

    final payload = {
      'action': 'punch',
      'empId': empId,
      'empName': empName,
      'pin': pin,
      'date': _ymd(DateTime.now()),
      'firstPunch': first.toLocal().toIso8601String(),
      'lastPunch': last.toLocal().toIso8601String(),
      'source': kIsWeb ? 'web' : 'app',
      'userAgent': kIsWeb ? Uri.base.toString() : '',

      // ✅ 後端需要：lat/lng/accuracyM
      'lat': gps.latitude,
      'lng': gps.longitude,
      'accuracyM': gps.accuracy,
    };

    final resp = await http
        .post(
          uri,
          headers: {'Content-Type': 'text/plain; charset=utf-8'},
          body: jsonEncode(payload),
        )
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException('上傳逾時（30秒）'),
        );

    if (resp.statusCode != 200) {
      throw '上傳失敗 HTTP ${resp.statusCode}：${resp.reasonPhrase ?? ''}';
    }

    final text = utf8.decode(resp.bodyBytes);
    if (!text.trimLeft().startsWith('{')) {
      throw '上傳回傳非 JSON（可能被導向 HTML）';
    }

    final j = jsonDecode(text);
    if (j is Map && j['ok'] != true) {
      throw '上傳失敗：${j['error'] ?? 'unknown'}';
    }
  }

  /// ✅ POST：例外申請（不需 GPS），送出後由後端通知主管簽核
  Future<void> _postExceptionRequest({
    required String empId,
    required String empName,
    required String pin,
    required DateTime first,
    required DateTime last,
    required String punchType,
    required DateTime requestedPunchAt,
    required String reason,
  }) async {
    final uri = Uri.parse(kApiUrl);

    final payload = {
      'action': 'exceptionRequest',
      'empId': empId,
      'empName': empName,
      'pin': pin,
      'date': _ymd(requestedPunchAt),
      'firstPunch': first.toLocal().toIso8601String(),
      'lastPunch': last.toLocal().toIso8601String(),
      'punchType': punchType,
      'requestedPunchAt': requestedPunchAt.toLocal().toIso8601String(),
      'reason': reason,
      'source': kIsWeb ? 'web' : 'app',
      'userAgent': kIsWeb ? Uri.base.toString() : '',
    };

    final resp = await http
        .post(
          uri,
          headers: {'Content-Type': 'text/plain; charset=utf-8'},
          body: jsonEncode(payload),
        )
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException('送出逾時（30秒）'),
        );

    if (resp.statusCode != 200) {
      throw '送出失敗 HTTP ${resp.statusCode}：${resp.reasonPhrase ?? ''}';
    }

    final text = utf8.decode(resp.bodyBytes);
    if (!text.trimLeft().startsWith('{')) {
      throw '送出回傳非 JSON（可能被導向 HTML）';
    }

    final j = jsonDecode(text);
    if (j is Map && j['ok'] != true) {
      throw '送出失敗：${j['error'] ?? 'unknown'}';
    }
  }

  /* ----------------------------- UI ----------------------------- */

  @override
  Widget build(BuildContext context) {
    final pageBg = const Color(0xFFE3F2FD);
    final cardBg = Colors.white;

    return Scaffold(
      backgroundColor: pageBg,
      body: SafeArea(
        child: StreamBuilder<DateTime>(
          stream: _nowTicker,
          builder: (context, snap) {
                _now = snap.data ?? _now;

                final today = DateFormat('yyyy/MM/dd').format(_now);
                final weekday = DateFormat('EEEE', 'zh_TW').format(_now);
                final time = DateFormat('HH:mm').format(_now);

                final emp = _currentEmployee;
                final shift = _todayShift;
                final eval = _lastEval;

                final pointsCount = _geoPoints.length;
                final nearestName = eval?.nearest?.name ?? '--';
                final nearestRadius = eval?.nearest?.radiusM;
                final nearestDist = eval?.nearestDistanceM;

                final gpsAcc = _lastGps?.accuracy;

                String allowText;
                IconData allowIcon;

                if (_selectedEmpId == null) {
                  allowText = '請先登入';
                  allowIcon = Icons.info_outline;
                } else if (_locationException) {
                  allowText = '⚠️ 已啟用例外申請（將送主管簽核）';
                  allowIcon = Icons.assignment_late_outlined;
                } else if (_lastGpsTime == null) {
                  allowText = '尚未檢核';
                  allowIcon = Icons.help_outline;
                } else if (_isAccuracyBad(gpsAcc)) {
                  allowText =
                      '⛔ 定位誤差過大（±${gpsAcc?.toStringAsFixed(0) ?? '--'}m，門檻 ${kProdMaxAcceptableAccuracyM.toStringAsFixed(0)}m）';
                  allowIcon = Icons.gps_off;
                } else if (eval?.allowed == true) {
                  allowText = '✅ 在範圍內';
                  allowIcon = Icons.verified;
                } else {
                  allowText = '⛔ 超出範圍，禁止打卡';
                  allowIcon = Icons.block;
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    today,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    weekday,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                time,
                                style: const TextStyle(
                                  fontSize: 86,
                                  fontWeight: FontWeight.w900,
                                  height: 1.0,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 18),

                              if (_loading)
                                const Center(
                                  child: Padding(
                                    padding: EdgeInsets.only(top: 30),
                                    child: Column(
                                      children: [
                                        CircularProgressIndicator(),
                                        SizedBox(height: 16),
                                        Text('正在載入資料...', style: TextStyle(fontSize: 16)),
                                      ],
                                    ),
                                  ),
                                )
                              else ...[
                                // ✅ 登入顯示
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: Colors.black12),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  child: Row(
                                    children: [
                                      Icon(Icons.badge_outlined, color: kPrimaryBlue),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _selectedEmpId == null
                                            ? const Text(
                                                '尚未登入',
                                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                              )
                                            : Text(
                                                '${_currentEmployee?.empName ?? ''}（${_selectedEmpId!}）',
                                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                              ),
                                      ),
                                      if (_selectedEmpId == null)
                                        FilledButton(
                                          onPressed: _showLoginDialog,
                                          child: const Text('登入'),
                                        )
                                      else
                                        TextButton.icon(
                                          onPressed: _logout,
                                          icon: const Icon(Icons.logout),
                                          label: const Text('登出'),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),

                                Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: cardBg,
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(color: Colors.black12),
                                  ),
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    children: [
                                      _infoRow(
                                        icon: Icons.schedule,
                                        title: '今日班表',
                                        subtitle: _selectedEmpId == null
                                            ? '請先登入以查看今日班表'
                                            : (shift == null
                                                ? '（今日未排班或 roster 無資料）'
                                                : '${shift.shiftId}  ${shift.start}-${shift.end}   ｜ 容許：上/下班各 ${shift.graceInMin}/${shift.graceOutMin} 分'),
                                        trailing: '',
                                      ),
                                      const Divider(height: 22),

                                      _infoRow(
                                        icon: Icons.location_on_outlined,
                                        title: '地理圍欄',
                                        subtitle: '多點模式：$pointsCount 個打卡點',
                                        trailing: '',
                                      ),
                                      const SizedBox(height: 10),

                                      _infoRow(
                                        icon: Icons.place_outlined,
                                        title: '最近點',
                                        subtitle: nearestRadius == null
                                            ? '尚未檢核'
                                            : '最近點：$nearestName（允許 ${nearestRadius.toStringAsFixed(0)}m）',
                                        trailing: '',
                                      ),
                                      const SizedBox(height: 10),

                                      _infoRow(
                                        icon: Icons.social_distance,
                                        title: '距離最近打卡點',
                                        subtitle: _lastGpsTime == null
                                            ? '尚未取得定位（按打卡時會檢核）'
                                            : '定位時間：${_hm(_lastGpsTime!)}（誤差 ±${(_lastGps?.accuracy ?? 0).toStringAsFixed(0)}m）',
                                        trailing: nearestDist == null
                                            ? '-- m'
                                            : '${nearestDist.toStringAsFixed(0)} m',
                                      ),
                                      const SizedBox(height: 10),

                                      _infoRow(
                                        icon: allowIcon,
                                        title: '是否允許打卡',
                                        subtitle: allowText,
                                        trailing: '',
                                      ),

                                      const Divider(height: 22),

                                      // ✅ 例外申請勾選 + 原因（必填）
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF7FAFF),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: const Color(0xFFBBDEFB)),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Checkbox(
                                                  value: _locationException,
                                                  onChanged: (v) {
                                                    setState(() {
                                                      _locationException = v == true;
                                                      if (_locationException) {
                                                        _exceptionPunchAt = DateTime.now();
                                                      } else {
                                                        _exceptionPunchType = 'CLOCK_IN';
                                                        _exceptionPunchAt = null;
                                                        _exceptionReasonCtrl.text = '';
                                                      }
                                                    });
                                                  },
                                                ),
                                                const Expanded(
                                                  child: Text(
                                                    '申請補打卡（送主管簽核）',
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight: FontWeight.w900,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            IgnorePointer(
                                              ignoring: !_locationException,
                                              child: Opacity(
                                                opacity: _locationException ? 1 : 0.45,
                                                child: SegmentedButton<String>(
                                                  segments: const [
                                                    ButtonSegment<String>(
                                                      value: 'CLOCK_IN',
                                                      icon: Icon(Icons.login_rounded),
                                                      label: Text('補上班卡'),
                                                    ),
                                                    ButtonSegment<String>(
                                                      value: 'CLOCK_OUT',
                                                      icon: Icon(Icons.logout_rounded),
                                                      label: Text('補下班卡'),
                                                    ),
                                                  ],
                                                  selected: {_exceptionPunchType},
                                                  onSelectionChanged: (values) {
                                                    setState(() {
                                                      _exceptionPunchType = values.first;
                                                    });
                                                  },
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            SizedBox(
                                              width: double.infinity,
                                              child: OutlinedButton.icon(
                                                onPressed: _locationException
                                                    ? _pickExceptionPunchTime
                                                    : null,
                                                icon: const Icon(Icons.schedule_rounded),
                                                label: Text(
                                                  _exceptionPunchAt == null
                                                      ? '選擇補打卡日期時間（必填）'
                                                      : '補打卡時間：${_ymd(_exceptionPunchAt!)} ${_hm(_exceptionPunchAt!)}',
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            TextField(
                                              controller: _exceptionReasonCtrl,
                                              enabled: _locationException,
                                              maxLines: 2,
                                              decoration: const InputDecoration(
                                                labelText: '原因（必填）',
                                                hintText: '例如：GPS 無法定位 / 室內無訊號 / 裝置故障…',
                                                border: OutlineInputBorder(),
                                                isDense: true,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '提醒：補打卡時間在主管核准後才會寫入打卡記錄；駁回時不會異動。',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.black.withOpacity(0.55),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const Divider(height: 22),

                                      _infoRow(
                                        icon: Icons.looks_one_rounded,
                                        title: '首次打卡',
                                        subtitle: 'First time（當日第一筆）',
                                        trailing: _selectedEmpId == null
                                            ? '--:--'
                                            : (_firstPunch == null ? '--:--' : _hm(_firstPunch!)),
                                      ),
                                      const SizedBox(height: 10),
                                      _infoRow(
                                        icon: Icons.access_time_rounded,
                                        title: '最後打卡',
                                        subtitle: 'Last time（當日最新）',
                                        trailing: _selectedEmpId == null
                                            ? '--:--'
                                            : (_lastPunch == null ? '--:--' : _hm(_lastPunch!)),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 24),

                                SizedBox(
                                  width: double.infinity,
                                  height: 58,
                                  child: FilledButton.icon(
                                    onPressed: _selectedEmpId == null ? _showLoginDialog : _doPunch,
                                    icon: Icon(_selectedEmpId == null ? Icons.login : Icons.fingerprint),
                                    label: Text(
                                      _selectedEmpId == null
                                          ? '登入後打卡'
                                          : (emp == null ? '送出' : '送出（${emp.empName}）'),
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),

                                if (_error != null)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Colors.black12),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            _error!,
                                            style: const TextStyle(fontSize: 14, height: 1.4),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],

                              const SizedBox(height: 10),
                              // ✅ 版本號（隨內容捲動，避免固定浮層蓋住送出按鈕）
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  kAppVersion,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black.withOpacity(0.35),
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
    );
  }

  Widget _infoRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required String trailing,
  }) {
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: kPrimaryBlue.withOpacity(0.10),
          child: Icon(icon, size: 20, color: kPrimaryBlue),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.black.withOpacity(0.55),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ),
        if (trailing.isNotEmpty)
          Text(
            trailing,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
      ],
    );
  }
}
