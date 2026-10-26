import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_sdk_app/main.dart';

void main() {
  testWidgets('Affiliate SDK Test App end-to-end smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    // Build the test app
    await tester.pumpWidget(const AffiliateSdkTestApp());
    await tester.pumpAndSettle();

    // Verify Title & Initialization
    expect(find.text('Affiliate SDK Inspector & Tester'), findsOneWidget);
    expect(find.text('SDK Active & Ready'), findsOneWidget);

    // 1. Test Ingesting Deep Link
    final parseLinkBtn = find.text('Parse & Ingest Link');
    await tester.ensureVisible(parseLinkBtn);
    await tester.tap(parseLinkBtn);
    await tester.pumpAndSettle();

    // Verify attribution updated on banner
    expect(find.textContaining('aff_superstar'), findsWidgets);
    expect(find.textContaining('clk_9988'), findsWidgets);

    // 2. Test Setting Referral Code
    final setCodeBtn = find.text('Set Code');
    await tester.ensureVisible(setCodeBtn);
    await tester.tap(setCodeBtn);
    await tester.pumpAndSettle();
    expect(find.textContaining('SUMMER2026'), findsWidgets);

    // 3. Test Tracking Conversion
    final trackConvBtn = find.text('Track Conversion');
    await tester.ensureVisible(trackConvBtn);
    await tester.tap(trackConvBtn);
    await tester.pumpAndSettle();

    // Verify backend received activity or log
    expect(find.textContaining('Recorded Conversion'), findsWidgets);

    // 4. Test Duplicate Conversion
    final duplicateBtn = find.text('Test Duplicate (409)');
    await tester.ensureVisible(duplicateBtn);
    await tester.tap(duplicateBtn);
    await tester.pumpAndSettle();
    expect(find.textContaining('duplicate'), findsWidgets);

    // 5. Test Clear Attribution
    final clearBtn = find.text('Clear Attribution');
    await tester.ensureVisible(clearBtn);
    await tester.tap(clearBtn);
    await tester.pumpAndSettle();
    expect(find.textContaining('None (Unattributed)'), findsOneWidget);
  });
}
