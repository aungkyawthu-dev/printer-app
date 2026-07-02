import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thrid_party_printer_app/main.dart';

void main() {
  testWidgets('shows printer setup home', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('receipt_bridge/printers'),
          (call) async => switch (call.method) {
            'getPrinters' => <dynamic>[],
            'isPrintServiceEnabled' => false,
            'getServiceDiagnostics' => <String, dynamic>{},
            _ => null,
          },
        );
    await tester.pumpWidget(const ReceiptBridgeApp());
    await tester.pumpAndSettle();
    expect(find.text('Receipt Bridge'), findsOneWidget);
    expect(find.text('Print service is disabled'), findsOneWidget);
  });
}
