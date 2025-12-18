import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const TapApp());
}

class TapApp extends StatelessWidget {
  const TapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ClockPage(),
    );
  }
}

class ClockPage extends StatefulWidget {
  const ClockPage({super.key});

  @override
  State<ClockPage> createState() => _ClockPageState();
}

class _ClockPageState extends State<ClockPage> {
  late final Timer _timer;
  DateTime now = DateTime.now();

  DateTime? firstTap;
  DateTime? lastTap;

  // UI 狀態
  double _btnScale = 1.0;
  bool _showChecked = false;

  // 防連點（30 秒）
  DateTime? _lastTapAt;
  static const int _cooldownSeconds = 30;

  // 儲存 key（依日期）
  String get _todayKey => DateFormat('yyyyMMdd').format(now);
  String get _kFirst => 'firstTap_$_todayKey';
  String get _kLast => 'lastTap_$_todayKey';
  String get _kLastTapAt => 'lastTapAt_$_todayKey';

  @override
  void initState() {
    super.initState();
    _loadToday();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _loadToday() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      firstTap = _parse(prefs.getString(_kFirst));
      lastTap = _parse(prefs.getString(_kLast));
      _lastTapAt = _parse(prefs.getString(_kLastTapAt));
    });
  }

  DateTime? _parse(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso);

  Future<void> _saveToday() async {
    final prefs = await SharedPreferences.getInstance();
    if (firstTap != null) {
      await prefs.setString(_kFirst, firstTap!.toIso8601String());
    }
    if (lastTap != null) {
      await prefs.setString(_kLast, lastTap!.toIso8601String());
    }
    if (_lastTapAt != null) {
      await prefs.setString(
          _kLastTapAt, _lastTapAt!.toIso8601String());
    }
  }

  Future<void> _tap() async {
    final nowTime = DateTime.now();

    // 防連點
    if (_lastTapAt != null) {
      final diff = nowTime.difference(_lastTapAt!).inSeconds;
      if (diff < _cooldownSeconds) {
        _snack('請 ${_cooldownSeconds - diff} 秒後再打卡');
        return;
      }
    }

    setState(() {
      firstTap ??= nowTime;
      lastTap = nowTime;
      _lastTapAt = nowTime;
      _showChecked = true;
    });

    await _saveToday();
    _snack('✔ 已打卡');

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showChecked = false);
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _fmtTime(DateTime? dt) =>
      dt == null ? '尚未打卡' : DateFormat('HH:mm').format(dt);

  @override
  Widget build(BuildContext context) {
    final dateText = DateFormat('yyyy/MM/dd').format(now);
    final timeText = DateFormat('HH:mm').format(now);
    final weekText = _weekZh(now.weekday);

    return Scaffold(
      backgroundColor: const Color(0xFFF4B400),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(dateText,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w900)),
                  Text(weekText,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w900)),
                ],
              ),

              const SizedBox(height: 10),

              Text(
                timeText,
                style: const TextStyle(
                    fontSize: 86,
                    height: 0.95,
                    fontWeight: FontWeight.w900),
              ),

              const SizedBox(height: 18),

              _buildCard(),

              const Spacer(),

              // ✔ 已打卡提示（浮在按鈕上方）
              AnimatedOpacity(
                opacity: _showChecked ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: const Center(
                  child: Text(
                    '✔ 已打卡',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Colors.black),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // 打卡按鈕（永遠顯示）
              GestureDetector(
                onTapDown: (_) => setState(() => _btnScale = 0.92),
                onTapUp: (_) => setState(() => _btnScale = 1.0),
                onTapCancel: () => setState(() => _btnScale = 1.0),
                onTap: _tap,
                child: AnimatedScale(
                  scale: _btnScale,
                  duration: const Duration(milliseconds: 120),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '打卡',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 22),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          _InfoRow(
            icon: Icons.looks_one,
            labelEn: 'First time',
            labelZh: '首次打卡',
            value: _fmtTime(firstTap),
          ),
          const Divider(height: 22),
          _InfoRow(
            icon: Icons.access_time,
            labelEn: 'Last time',
            labelZh: '最後打卡',
            value: _fmtTime(lastTap),
          ),
        ],
      ),
    );
  }

  String _weekZh(int w) =>
      ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][w - 1];
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String labelEn;
  final String labelZh;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.labelEn,
    required this.labelZh,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(labelEn,
                  style: const TextStyle(
                      fontSize: 13, color: Colors.black54)),
              Text(labelZh,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        Text(value,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w900)),
      ],
    );
  }
}
