// ผู้พัฒนาและออกแบบโปรแกรม: วรรณเมฑี นามบุดดี
//
// The developer credit, in one place (the server keeps the same text in app_credits.py). Every edition keeps it,
// the blank copy on GitHub too: its licence (LICENSE, CC BY-NC-SA 4.0) asks schools to keep this name.
import 'package:flutter/material.dart';

const String kDeveloperName = 'วรรณเมฑี นามบุดดี';
const String kCreditLine = 'พัฒนาและออกแบบโดย วรรณเมฑี นามบุดดี';
const String kCopyright = '© 2569 วรรณเมฑี นามบุดดี';

/// The small credit line under the side menu and the login / first-run dialogs.
class AppCreditText extends StatelessWidget {
  final Color? color;
  final double fontSize;
  const AppCreditText({super.key, this.color, this.fontSize = 10});

  @override
  Widget build(BuildContext context) {
    return Text(
      '$kCopyright\n$kCreditLine',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: 'Sarabun',
        fontSize: fontSize,
        height: 1.35,
        color: color ?? Colors.grey.shade600,
      ),
    );
  }
}
