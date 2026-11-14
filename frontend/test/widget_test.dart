import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';

void main() {
  testWidgets('App shell renders navigation destinations', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpWidget(const SGSApp());
    await tester.pump();

    expect(find.text('แปลงไฟล์'), findsWidgets);
    expect(find.text('คลังข้อมูล'), findsOneWidget);
    expect(find.text('ตั้งค่า'), findsOneWidget);
  });
}
