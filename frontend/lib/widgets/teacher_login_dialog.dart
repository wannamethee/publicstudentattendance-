import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import './app_3d_button.dart';
import '../services/api_service.dart';
import '../models/logged_in_teacher.dart';
import '../app_credits.dart';

class TeacherLoginDialog extends StatefulWidget {
  final ApiService apiService;
  final bool canCancel;

  const TeacherLoginDialog({
    super.key,
    required this.apiService,
    this.canCancel = false,
  });

  static Future<LoggedInTeacher?> show(
    BuildContext context, {
    required ApiService apiService,
    bool canCancel = false,
  }) {
    return showDialog<LoggedInTeacher>(
      context: context,
      barrierDismissible: canCancel,
      builder: (ctx) => PopScope(
        canPop: canCancel,
        child: TeacherLoginDialog(
          apiService: apiService,
          canCancel: canCancel,
        ),
      ),
    );
  }

  @override
  State<TeacherLoginDialog> createState() => _TeacherLoginDialogState();
}

class _TeacherLoginDialogState extends State<TeacherLoginDialog> {
  final TextEditingController _codeCtrl = TextEditingController();
  final TextEditingController _pinCtrl = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _pinFocusNode = FocusNode();
  bool _isLoading = false;
  bool _obscurePin = true;
  bool _studentMode = false; // นักเรียน: student ID as username and password
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _codeFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _pinCtrl.dispose();
    _codeFocusNode.dispose();
    _pinFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final code = _codeCtrl.text.trim();
    final pin = _pinCtrl.text.trim();

    if (code.isEmpty) {
      setState(() {
        _errorMessage = _studentMode ? 'กรุณาระบุรหัสประจำตัวนักเรียน' : 'กรุณาระบุรหัสประจำตัวครู';
      });
      _codeFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final teacher = _studentMode
          ? await widget.apiService.loginStudent(code, pin)
          : await widget.apiService.loginTeacher(
              code,
              pin: pin.isNotEmpty ? pin : null,
            );
      if (mounted) {
        Navigator.of(context).pop(teacher);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          final msg = e.toString().replaceFirst('Exception: ', '');
          _errorMessage = msg.isNotEmpty ? msg : 'รหัสครูหรือรหัสใช้งานไม่ถูกต้อง กรุณาตรวจสอบอีกครั้ง';
        });
      }
    }
  }


  Future<void> _handleGuestLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final guest = await widget.apiService.loginAsGuest();
      if (mounted) {
        Navigator.of(context).pop(guest);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'ไม่สามารถเข้าใช้งานในฐานะบุคคลทั่วไปได้';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.gold, width: 1.5),
      ),
      elevation: 8,
      child: Container(
        width: 450,
        padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Logo & School Identity
            Center(
              child: ValueListenableBuilder<int>(
                valueListenable: widget.apiService.schoolLogoNotifier,
                builder: (context, logoVer, child) {
                  return Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.gold, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.purpleDeeper.withValues(alpha: 0.15),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.network(
                      widget.apiService.getSchoolLogoUrl(),
                      fit: BoxFit.contain,
                      errorBuilder: (ctx, err, stack) => Icon(
                        Icons.school_rounded,
                        size: 40,
                        color: cs.primary,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),

            // School Name & Title
            ValueListenableBuilder<String>(
              valueListenable: widget.apiService.schoolNameNotifier,
              builder: (context, schoolName, _) {
                return Text(
                  schoolName,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.primary,
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              'เข้าสู่ระบบ SGS ปพ.5',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.badge_outlined), label: Text('ครู / บุคลากร')),
                ButtonSegment(value: true, icon: Icon(Icons.school_outlined), label: Text('นักเรียน')),
              ],
              selected: {_studentMode},
              onSelectionChanged: _isLoading
                  ? null
                  : (sel) => setState(() {
                        _studentMode = sel.first;
                        _errorMessage = null;
                        _codeCtrl.clear();
                        _pinCtrl.clear();
                      }),
            ),
            const SizedBox(height: 10),
            Text(
              _studentMode
                  ? 'นักเรียนดูได้เฉพาะเวลาเรียนและการขาดเรียนของตนเอง'
                  : 'กรุณาระบุรหัสประจำตัวครู และรหัสใช้งาน (PIN) เพื่อเข้าใช้งานและกำหนดสิทธิ์ตามบทบาท',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),

            // Teacher Code Input Field
            TextField(
              controller: _codeCtrl,
              focusNode: _codeFocusNode,
              enabled: !_isLoading,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _pinFocusNode.requestFocus(),
              keyboardType: TextInputType.text,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              decoration: InputDecoration(
                labelText: _studentMode ? 'รหัสประจำตัวนักเรียน' : 'รหัสประจำตัวครู (Teacher Code)',
                hintText: _studentMode ? 'ใส่ 0 นำหน้าด้วย เช่น 01234' : null,
                prefixIcon: Icon(_studentMode ? Icons.school_outlined : Icons.badge_outlined),
                suffixIcon: _codeCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 20),
                        onPressed: () {
                          _codeCtrl.clear();
                          setState(() {});
                        },
                      )
                    : null,
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
            const SizedBox(height: 14),

            // Login PIN Input Field (Up to 4 digits)
            TextField(
              controller: _pinCtrl,
              focusNode: _pinFocusNode,
              enabled: !_isLoading,
              obscureText: _obscurePin,
              maxLength: _studentMode ? 13 : 6,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _handleLogin(),
              keyboardType: TextInputType.number,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 2),
              decoration: InputDecoration(
                labelText: _studentMode ? 'รหัสผ่าน' : 'รหัสใช้งาน (Login PIN ไม่เกิน 6 ตัวเลข)',
                hintText: _studentMode ? 'รหัสประจำตัวนักเรียน (มี 0 นำหน้า)' : null,
                counterText: '',
                prefixIcon: const Icon(Icons.pin_outlined),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePin ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 20,
                  ),
                  tooltip: _obscurePin ? 'แสดงรหัสใช้งาน' : 'ซ่อนรหัสใช้งาน',
                  onPressed: () => setState(() => _obscurePin = !_obscurePin),
                ),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                errorText: _errorMessage,
                errorMaxLines: 2,
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
            const SizedBox(height: 12),

            // Helpful Quick Suggestion / Hint Box
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.goldLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF78350F)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _studentMode
                          ? '• ชื่อผู้ใช้และรหัสผ่าน คือรหัสประจำตัวนักเรียน (มี 0 นำหน้า)\n• ลืมรหัสประจำตัว สอบถามครูที่ปรึกษา'
                          : '• ใช้รหัสครูและรหัสใช้งาน (PIN) ที่ได้รับจากผู้ดูแลระบบ\n• ลืม PIN ติดต่อผู้ดูแลระบบเพื่อตั้งใหม่',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF78350F),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Submit Button: Tactile 3D Button with Gold Trim
            App3DButton.primary(
              onPressed: _isLoading ? null : _handleLogin,
              fullWidth: true,
              isLoading: _isLoading,
              icon: Icons.login_rounded,
              label: _studentMode ? 'เข้าสู่ระบบนักเรียน' : 'เข้าสู่ระบบครู / บุคลากร',
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),

            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Divider(color: AppColors.gold.withValues(alpha: 0.3))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'หรือเข้าเยี่ยมชมระบบโดยไม่ต้องใส่รหัส',
                    style: TextStyle(
                      fontFamily: 'Sarabun',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
                Expanded(child: Divider(color: AppColors.gold.withValues(alpha: 0.3))),
              ],
            ),
            const SizedBox(height: 14),

            // Guest Login Button: No password required
            App3DButton.secondary(
              onPressed: _isLoading ? null : _handleGuestLogin,
              fullWidth: true,
              icon: Icons.visibility_rounded,
              label: 'บุคคลทั่วไป (แดชบอร์ดไม่แสดงชื่อ และตารางสอน)',
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),

            if (widget.canCancel) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                child: const Text('ยกเลิก'),
              ),
            ],
            const SizedBox(height: 14),
            const AppCreditText(),
          ],
        ),
        ),
      ),
    );
  }
}
