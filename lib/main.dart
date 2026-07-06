import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const ReceiptBridgeApp());

class ReceiptBridgeApp extends StatelessWidget {
  const ReceiptBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff087f72),
      brightness: Brightness.light,
      surface: const Color(0xfff7faf9),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'HapEye Print',
      theme: ThemeData(
        colorScheme: colors,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff3f7f6),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff3f7f6),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xffdfe9e6)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          elevation: 3,
          shape: StadiumBorder(),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xffb8c9c5)),
          ),
        ),
      ),
      home: const PrinterHomePage(),
    );
  }
}

class NativePrinterApi {
  static const _channel = MethodChannel('receipt_bridge/printers');

  Future<List<Map<String, dynamic>>> getPrinters() async {
    final value = await _channel.invokeListMethod<dynamic>('getPrinters') ?? [];
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  Future<void> savePrinter(Map<String, dynamic> printer) =>
      _channel.invokeMethod('savePrinter', printer);

  Future<void> deletePrinter(String id) =>
      _channel.invokeMethod('deletePrinter', {'id': id});

  Future<List<Map<String, dynamic>>> getBluetoothDevices() async {
    final value =
        await _channel.invokeListMethod<dynamic>('getBluetoothDevices') ?? [];
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> getUsbDevices() async {
    final value =
        await _channel.invokeListMethod<dynamic>('getUsbDevices') ?? [];
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  Future<void> requestUsbPermission(String address) =>
      _channel.invokeMethod('requestUsbPermission', {'address': address});

  Future<void> openPrintSettings() =>
      _channel.invokeMethod('openPrintSettings');

  Future<bool> isPrintServiceEnabled() async =>
      await _channel.invokeMethod<bool>('isPrintServiceEnabled') ?? false;

  Future<Map<String, dynamic>> getCacheInfo() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'getCacheInfo',
    );
    return value ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> getServiceDiagnostics() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'getServiceDiagnostics',
    );
    return value ?? <String, dynamic>{};
  }

  Future<void> clearPrintCache() => _channel.invokeMethod('clearPrintCache');

  Future<void> testPrinter(String id) =>
      _channel.invokeMethod('testPrinter', {'id': id});
}

class PrinterHomePage extends StatefulWidget {
  const PrinterHomePage({super.key});

  @override
  State<PrinterHomePage> createState() => _PrinterHomePageState();
}

class _PrinterHomePageState extends State<PrinterHomePage>
    with WidgetsBindingObserver {
  final _api = NativePrinterApi();
  List<Map<String, dynamic>> _printers = [];
  bool _loading = true;
  bool _serviceEnabled = false;
  Map<String, dynamic> _cacheInfo = const {'count': 0, 'bytes': 0};
  Map<String, dynamic> _diagnostics = const {};
  String? _testingPrinterId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        _api.getPrinters(),
        _api.isPrintServiceEnabled(),
        _api.getCacheInfo(),
        _api.getServiceDiagnostics(),
      ]);
      if (mounted) {
        setState(() {
          _printers = results[0] as List<Map<String, dynamic>>;
          _serviceEnabled = results[1] as bool;
          _cacheInfo = results[2] as Map<String, dynamic>;
          _diagnostics = results[3] as Map<String, dynamic>;
        });
      }
    } on PlatformException catch (error) {
      _message(error.message ?? 'Could not load printers');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addOrEdit([Map<String, dynamic>? printer]) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => PrinterEditorPage(printer: printer)),
    );
    if (result == null) return;
    try {
      await _api.savePrinter(result);
      await _load();
      _message('Printer saved');
    } on PlatformException catch (error) {
      _message(error.message ?? 'Could not save printer');
    }
  }

  Future<void> _delete(Map<String, dynamic> printer) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove printer?'),
        content: Text(
          '${printer['name']} will disappear from Android printing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _api.deletePrinter(printer['id'] as String);
    await _load();
  }

  Future<void> _testPrinter(Map<String, dynamic> printer) async {
    final id = printer['id'] as String;
    setState(() => _testingPrinterId = id);
    try {
      await _api.testPrinter(id);
      _message('Test receipt sent successfully');
    } on PlatformException catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.print_disabled_outlined),
            title: const Text('Test print failed'),
            content: Text(
              '${error.message ?? 'Printer did not respond'}\n\n'
              'Bluetooth: restart the printer, remove it from Android Bluetooth settings, pair it again, then retry.\n\n'
              'USB: reconnect the OTG cable and approve USB access.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testingPrinterId = null);
    }
  }

  Future<void> _clearCache() async {
    await _api.clearPrintCache();
    await _load();
    _message('Print cache cleared');
  }

  Future<void> _showDiagnostics() async {
    final events = (_diagnostics['events'] as List<dynamic>? ?? const [])
        .cast<String>();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PrintService diagnostics'),
        content: SizedBox(
          width: double.maxFinite,
          child: events.isEmpty
              ? const Text(
                  'No Android PrintService event has been recorded yet.',
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: events.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (_, index) => SelectableText(events[index]),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openPrivacyPolicy() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyPage()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'HapEye Printer',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            onPressed: _openPrivacyPolicy,
            icon: const Icon(Icons.privacy_tip_outlined),
            tooltip: 'Privacy policy',
          ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOrEdit,
        icon: const Icon(Icons.add),
        label: const Text('Add printer'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                const _BrandHero(),
                const SizedBox(height: 14),
                _ActivationCard(
                  enabled: _serviceEnabled,
                  onOpen: _api.openPrintSettings,
                ),
                const SizedBox(height: 10),
                _DiagnosticsCard(info: _diagnostics, onView: _showDiagnostics),
                const SizedBox(height: 10),
                _CacheCard(info: _cacheInfo, onClear: _clearCache),
                const SizedBox(height: 22),
                Text(
                  'Your printers',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                if (_printers.isEmpty)
                  const _EmptyState()
                else
                  ..._printers.map(
                    (printer) => _PrinterCard(
                      printer: printer,
                      onTap: () => _addOrEdit(printer),
                      onDelete: () => _delete(printer),
                      onTest: () => _testPrinter(printer),
                      testing: _testingPrinterId == printer['id'],
                    ),
                  ),
                const SizedBox(height: 18),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'After setup, open Chrome → Print → Select printer → Receipt Bridge. Choose an 80 mm roll size and print.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _DeveloperFooter(onPrivacy: _openPrivacyPolicy),
              ],
            ),
    );
  }
}

class _BrandHero extends StatelessWidget {
  const _BrandHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff087f72), Color(0xff075b67)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26075b67),
            blurRadius: 22,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.receipt_long_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Print without limits',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'Ethernet  •  Bluetooth  •  USB',
                  style: TextStyle(color: Color(0xffd6f5ef), fontSize: 13),
                ),
                SizedBox(height: 3),
                Text(
                  '72, 80 and 100 mm ESC/POS rolls',
                  style: TextStyle(color: Color(0xffb9e2dc), fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeveloperFooter extends StatelessWidget {
  const _DeveloperFooter({required this.onPrivacy});
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Divider(),
        const SizedBox(height: 14),
        const Icon(Icons.code_rounded, color: Color(0xff087f72)),
        const SizedBox(height: 8),
        const Text(
          'Developed by Aung Kyaw Thu',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        const Text(
          'Receipt Bridge • Version 1.8.0',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        TextButton.icon(
          onPressed: onPrivacy,
          icon: const Icon(Icons.shield_outlined, size: 18),
          label: const Text('Privacy Policy'),
        ),
      ],
    );
  }
}

class _ActivationCard extends StatelessWidget {
  const _ActivationCard({required this.enabled, required this.onOpen});
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: enabled ? const Color(0xffd9f3ef) : const Color(0xffffe4dc),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: enabled
                      ? const Color(0xff0a7c72)
                      : const Color(0xffb83b2d),
                  foregroundColor: Colors.white,
                  child: Icon(
                    enabled ? Icons.check : Icons.warning_amber_rounded,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    enabled
                        ? 'Enabled in Android settings'
                        : 'Print service is disabled',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              enabled
                  ? 'Android’s switch is ON. If Tecno Print Spooler still reports “not enabled”, open settings below, turn Receipt Bridge OFF and ON again, cancel every old job, and restart the phone.'
                  : 'Tap below, select Receipt Bridge, then turn on "Use print service". Cancel the failed job and print it again.',
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.settings),
              label: Text(
                enabled
                    ? 'Repair / view print settings'
                    : 'Enable in Android settings',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.info, required this.onView});
  final Map<String, dynamic> info;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final lastEvent = info['lastEvent'] as String? ?? 'No service event yet';
    final connected = info['connected'] as bool? ?? false;
    return Card(
      elevation: 0,
      child: ListTile(
        leading: Icon(
          connected ? Icons.sync : Icons.history,
          color: connected ? const Color(0xff0a7c72) : null,
        ),
        title: const Text('Android PrintService log'),
        subtitle: Text(lastEvent, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: TextButton(onPressed: onView, child: const Text('View')),
      ),
    );
  }
}

class _CacheCard extends StatelessWidget {
  const _CacheCard({required this.info, required this.onClear});
  final Map<String, dynamic> info;
  final VoidCallback onClear;

  String _size(num bytes) {
    if (bytes < 1024) return '${bytes.toInt()} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final count = (info['count'] as num?)?.toInt() ?? 0;
    final bytes = info['bytes'] as num? ?? 0;
    final limit = info['limitBytes'] as num? ?? 50 * 1024 * 1024;
    return Card(
      elevation: 0,
      child: ListTile(
        leading: const Icon(Icons.storage_outlined),
        title: const Text('Print-job cache'),
        subtitle: Text(
          '$count failed ${count == 1 ? 'job' : 'jobs'} • ${_size(bytes)} / ${_size(limit)}',
        ),
        trailing: TextButton(
          onPressed: count == 0 ? null : onClear,
          child: const Text('Clear'),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Column(
      children: [
        Icon(Icons.print_disabled_outlined, size: 48, color: Colors.black45),
        SizedBox(height: 12),
        Text(
          'No printers yet',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 6),
        Text(
          'Add an Ethernet, Bluetooth, or USB receipt printer.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.printer,
    required this.onTap,
    required this.onDelete,
    required this.onTest,
    required this.testing,
  });
  final Map<String, dynamic> printer;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onTest;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final type = printer['type'] as String? ?? 'ethernet';
    final icon = switch (type) {
      'bluetooth' => Icons.bluetooth,
      'usb' => Icons.usb,
      _ => Icons.lan,
    };
    final address = printer['address'] as String? ?? '';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          ListTile(
            onTap: onTap,
            contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            leading: CircleAvatar(child: Icon(icon)),
            title: Text(
              printer['name'] as String? ?? '80 mm Printer',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${type.toUpperCase()}  •  $address\n${printer['paperWidth'] ?? 80} mm roll • 72 mm printable head',
            ),
            isThreeLine: true,
            trailing: PopupMenuButton<String>(
              onSelected: (value) => value == 'edit' ? onTap() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Remove')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: testing ? null : onTest,
                icon: testing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.receipt_long_outlined),
                label: Text(
                  testing ? 'Printing test page…' : 'Print test page',
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Tests the printer directly; Chrome print service is not required.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class PrinterEditorPage extends StatefulWidget {
  const PrinterEditorPage({super.key, this.printer});
  final Map<String, dynamic>? printer;

  @override
  State<PrinterEditorPage> createState() => _PrinterEditorPageState();
}

class _PrinterEditorPageState extends State<PrinterEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _api = NativePrinterApi();
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late String _type;
  late int _width;
  late int _dpi;
  late bool _cut;
  late String _paperSaving;
  late bool _keepAlive;
  late int _density;
  late String _cashDrawer;
  late String _alarm;
  late bool _feedAtEnd;
  late int _feedLines;
  late int _paperWidth;
  late bool _fitWidth;
  late int _contentScale;
  late int _sideMarginMm;
  List<Map<String, dynamic>> _devices = [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    final value = widget.printer;
    _name = TextEditingController(
      text: value?['name'] as String? ?? '80 mm Receipt Printer',
    );
    _address = TextEditingController(text: value?['address'] as String? ?? '');
    _port = TextEditingController(text: '${value?['port'] ?? 9100}');
    _type = value?['type'] as String? ?? 'ethernet';
    _width = 72;
    _dpi = value?['dpi'] as int? ?? 203;
    _cut = value?['cut'] as bool? ?? true;
    _paperSaving = value?['paperSaving'] as String? ?? 'compact';
    _keepAlive = value?['keepAlive'] as bool? ?? true;
    _density = value?['density'] as int? ?? 3;
    _cashDrawer = value?['cashDrawer'] as String? ?? 'none';
    _alarm = value?['alarm'] as String? ?? 'none';
    _feedAtEnd = value?['feedAtEnd'] as bool? ?? true;
    _feedLines = value?['feedLines'] as int? ?? 3;
    _paperWidth = value?['paperWidth'] as int? ?? 80;
    _fitWidth = value?['fitWidth'] as bool? ?? true;
    _contentScale = value?['contentScale'] as int? ?? 85;
    _sideMarginMm = value?['sideMarginMm'] as int? ?? 1;
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      _devices = _type == 'bluetooth'
          ? await _api.getBluetoothDevices()
          : await _api.getUsbDevices();
      if (mounted && _devices.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _type == 'bluetooth'
                  ? 'No paired Bluetooth devices found. Pair the printer in Android settings first.'
                  : 'No USB printer found. Connect it with an OTG cable.',
            ),
          ),
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message ?? 'Scan failed')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _chooseDevice(Map<String, dynamic> device) async {
    _address.text = device['address'] as String;
    if (_type == 'usb' && device['permission'] != true) {
      await _api.requestUsbPermission(_address.text);
    }
    setState(() {});
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, <String, dynamic>{
      'id':
          widget.printer?['id'] ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      'name': _name.text.trim(),
      'type': _type,
      'address': _address.text.trim(),
      'port': int.tryParse(_port.text) ?? 9100,
      'printableWidth': _width,
      'dpi': _dpi,
      'cut': _cut,
      'paperSaving': _paperSaving,
      'keepAlive': _keepAlive,
      'density': _density,
      'cashDrawer': _cashDrawer,
      'alarm': _alarm,
      'feedAtEnd': _feedAtEnd,
      'feedLines': _feedLines,
      'paperWidth': _paperWidth,
      'fitWidth': _fitWidth,
      'contentScale': _contentScale,
      'sideMarginMm': _sideMarginMm,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.printer == null ? 'Add printer' : 'Edit printer'),
        actions: [
          IconButton(
            onPressed: _save,
            icon: const Icon(Icons.check),
            tooltip: 'Save',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Printer name',
                prefixIcon: Icon(Icons.print),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a printer name'
                  : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Connection type',
                prefixIcon: Icon(Icons.cable),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'ethernet',
                  child: Text('Ethernet / Wi-Fi (TCP)'),
                ),
                DropdownMenuItem(
                  value: 'bluetooth',
                  child: Text('Bluetooth Classic'),
                ),
                DropdownMenuItem(value: 'usb', child: Text('USB / OTG')),
              ],
              onChanged: (value) => setState(() {
                _type = value!;
                _address.clear();
                _devices = [];
              }),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _address,
              readOnly: _type != 'ethernet',
              decoration: InputDecoration(
                labelText: switch (_type) {
                  'bluetooth' => 'Bluetooth address',
                  'usb' => 'USB device',
                  _ => 'IP address',
                },
                hintText: _type == 'ethernet' ? '192.168.1.100' : null,
                prefixIcon: Icon(
                  _type == 'bluetooth'
                      ? Icons.bluetooth
                      : _type == 'usb'
                      ? Icons.usb
                      : Icons.lan,
                ),
                suffixIcon: _type == 'ethernet'
                    ? null
                    : IconButton(
                        onPressed: _scanning ? null : _scan,
                        icon: _scanning
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.search),
                      ),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Choose or enter a device'
                  : null,
            ),
            if (_devices.isNotEmpty) ...[
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: _devices
                      .map(
                        (device) => ListTile(
                          leading: Icon(
                            _type == 'usb' ? Icons.usb : Icons.bluetooth,
                          ),
                          title: Text(device['name'] as String? ?? 'Printer'),
                          subtitle: Text(device['address'] as String),
                          trailing: _address.text == device['address']
                              ? const Icon(Icons.check_circle)
                              : null,
                          onTap: () => _chooseDevice(device),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
            if (_type == 'ethernet') ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  prefixIcon: Icon(Icons.numbers),
                  helperText: 'Most ESC/POS network printers use port 9100',
                ),
                validator: (value) => int.tryParse(value ?? '') == null
                    ? 'Enter a valid port'
                    : null,
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Paper & output',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => setState(() {
                  _paperWidth = 80;
                  _fitWidth = true;
                  _dpi = 203;
                  _paperSaving = 'compact';
                  _density = 3;
                  _contentScale = 85;
                  _sideMarginMm = 1;
                }),
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Use recommended 80 mm settings'),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Roll paper size',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 80, label: Text('80 mm')),
                ButtonSegment(value: 72, label: Text('72 mm')),
                ButtonSegment(value: 100, label: Text('100 mm')),
              ],
              selected: {_paperWidth},
              onSelectionChanged: (value) =>
                  setState(() => _paperWidth = value.first),
            ),
            const SizedBox(height: 6),
            const Text(
              '72, 80 and 100 mm roll sizes are available in Chrome. Output is fitted to this printer’s 72 mm / 576-dot thermal head.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 18),
            const Text(
              'Receipt layout',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.fit_screen),
                  label: Text('Full paper'),
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.aspect_ratio),
                  label: Text('Small original'),
                ),
              ],
              selected: {_fitWidth},
              onSelectionChanged: (value) =>
                  setState(() => _fitWidth = value.first),
            ),
            const SizedBox(height: 6),
            Text(
              _fitWidth
                  ? 'Centers the receipt and enlarges it to full width with safe left/right margins.'
                  : 'Keeps the webpage’s small receipt size, but centers it on the paper.',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (!_fitWidth) ...[
              const SizedBox(height: 8),
              const Card(
                color: Color(0xffffe4dc),
                child: ListTile(
                  leading: Icon(Icons.warning_amber_rounded),
                  title: Text('This mode prints small'),
                  subtitle: Text(
                    'Select Full paper to produce the large receipt layout you requested.',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Font & content size',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$_contentScale%',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            Slider(
              value: _contentScale.toDouble(),
              min: 65,
              max: 95,
              divisions: 6,
              label: '$_contentScale%',
              onChanged: _fitWidth
                  ? (value) => setState(() => _contentScale = value.round())
                  : null,
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Smaller', style: TextStyle(fontSize: 12)),
                Text('Recommended 85%', style: TextStyle(fontSize: 12)),
                Text('Larger', style: TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Scales the complete Chrome receipt so text, columns, logo and barcode stay aligned.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Side margin',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$_sideMarginMm mm',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            Slider(
              value: _sideMarginMm.toDouble(),
              min: 0,
              max: 6,
              divisions: 6,
              label: '$_sideMarginMm mm',
              onChanged: _fitWidth
                  ? (value) => setState(() => _sideMarginMm = value.round())
                  : null,
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Full width', style: TextStyle(fontSize: 12)),
                Text('Recommended 1 mm', style: TextStyle(fontSize: 12)),
                Text('More margin', style: TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'This is additional margin inside the printer’s physical 72 mm head.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _dpi,
              decoration: const InputDecoration(
                labelText: 'Printer resolution',
              ),
              items: const [
                DropdownMenuItem(value: 203, child: Text('203 dpi (standard)')),
                DropdownMenuItem(value: 300, child: Text('300 dpi')),
              ],
              onChanged: (value) => setState(() => _dpi = value!),
            ),
            if (_dpi == 300) ...[
              const SizedBox(height: 8),
              const Card(
                color: Color(0xffffe4dc),
                child: ListTile(
                  leading: Icon(Icons.warning_amber_rounded),
                  title: Text('300 dpi requires a 300 dpi printer'),
                  subtitle: Text(
                    'For your standard 576-dot printer, select 203 dpi to prevent shifting and clipping.',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _paperSaving,
              decoration: const InputDecoration(
                labelText: 'Paper saving',
                prefixIcon: Icon(Icons.content_cut),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'compact',
                  child: Text('Compact — remove blank space'),
                ),
                DropdownMenuItem(
                  value: 'none',
                  child: Text('None — match full preview page'),
                ),
              ],
              onChanged: (value) => setState(() => _paperSaving = value!),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _density,
              decoration: const InputDecoration(
                labelText: 'Print density',
                prefixIcon: Icon(Icons.tonality),
              ),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 — lightest')),
                DropdownMenuItem(value: 2, child: Text('2 — light')),
                DropdownMenuItem(value: 3, child: Text('3 — normal')),
                DropdownMenuItem(value: 4, child: Text('4 — dark')),
                DropdownMenuItem(value: 5, child: Text('5 — darkest')),
              ],
              onChanged: (value) => setState(() => _density = value!),
            ),
            const Card(
              elevation: 0,
              child: ListTile(
                leading: Icon(Icons.copy_all_outlined),
                title: Text('Copy count'),
                subtitle: Text(
                  'Choose Copies in Chrome’s print preview; Receipt Bridge prints that exact count.',
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Feed paper at end of job'),
              subtitle: Text(
                _feedAtEnd
                    ? 'Feed $_feedLines lines before cutting'
                    : 'No extra feed — most compact output',
              ),
              value: _feedAtEnd,
              onChanged: (value) => setState(() => _feedAtEnd = value),
            ),
            if (_feedAtEnd)
              DropdownButtonFormField<int>(
                initialValue: _feedLines,
                decoration: const InputDecoration(labelText: 'End feed lines'),
                items: List.generate(
                  9,
                  (index) => DropdownMenuItem(
                    value: index + 1,
                    child: Text(
                      '${index + 1} ${index == 0 ? 'line' : 'lines'}',
                    ),
                  ),
                ),
                onChanged: (value) => setState(() => _feedLines = value!),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cut paper after job'),
              subtitle: const Text(
                'Requires a printer with an automatic cutter',
              ),
              value: _cut,
              onChanged: (value) => setState(() => _cut = value),
            ),
            const SizedBox(height: 20),
            Text(
              'Printer hardware',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _alarm,
              decoration: const InputDecoration(
                labelText: 'Alarm / buzzer',
                prefixIcon: Icon(Icons.notifications_active_outlined),
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Off')),
                DropdownMenuItem(value: 'before', child: Text('Before print')),
                DropdownMenuItem(value: 'after', child: Text('After print')),
              ],
              onChanged: (value) => setState(() => _alarm = value!),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _cashDrawer,
              decoration: const InputDecoration(
                labelText: 'Cash drawer pulse',
                prefixIcon: Icon(Icons.point_of_sale_outlined),
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Off')),
                DropdownMenuItem(
                  value: 'drawer1',
                  child: Text('Drawer connector 1'),
                ),
                DropdownMenuItem(
                  value: 'drawer2',
                  child: Text('Drawer connector 2'),
                ),
              ],
              onChanged: (value) => setState(() => _cashDrawer = value!),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep print connection alive'),
              subtitle: const Text(
                'Reuse Ethernet or Bluetooth connection between jobs',
              ),
              value: _keepAlive,
              onChanged: (value) => setState(() => _keepAlive = value),
            ),
            const Text(
              'Alarm and cash drawer commands require compatible ESC/POS hardware.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save printer'),
            ),
          ],
        ),
      ),
    );
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xff087f72), Color(0xff075b67)],
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Column(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Color(0x33ffffff),
                  foregroundColor: Colors.white,
                  child: Icon(Icons.shield_rounded, size: 32),
                ),
                SizedBox(height: 12),
                Text(
                  'Your print data stays on your device',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Effective 2 July 2026',
                  style: TextStyle(color: Color(0xffd6f5ef)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _PolicySection(
            icon: Icons.person_outline,
            title: 'Developer',
            body:
                'Receipt Bridge is developed and maintained by Aung Kyaw Thu. This policy applies only to Receipt Bridge, not to Chrome, your POS website, Android Print Spooler, or the printer manufacturer.',
          ),
          const _PolicySection(
            icon: Icons.storage_outlined,
            title: 'Information stored locally',
            body:
                'The app stores printer names, connection types, IP addresses, ports, Bluetooth addresses, USB device identifiers, and printer preferences on your Android device. These settings are used only to connect to printers you configure.',
          ),
          const _PolicySection(
            icon: Icons.description_outlined,
            title: 'Print documents',
            body:
                'Android provides the selected print document to Receipt Bridge when you print. The document may contain personal or business information from its source. Successful jobs are deleted from the app cache after printing. Failed jobs may remain in private app storage, up to the displayed 50 MB limit, so failures can be diagnosed. You can clear this cache from the home screen.',
          ),
          const _PolicySection(
            icon: Icons.cable_outlined,
            title: 'Permissions and connections',
            body:
                'Nearby-device permission is used to find and connect to paired Bluetooth printers. USB access is used only for a USB printer you approve. Network access sends print data directly to the IP address and port you configure, normally on your local network.',
          ),
          const _PolicySection(
            icon: Icons.share_outlined,
            title: 'Collection and sharing',
            body:
                'Receipt Bridge does not include advertising or analytics and does not upload printer settings or documents to a developer-operated server. The developer does not sell or share your data. Print data is transmitted only to the printer destination you select.',
          ),
          const _PolicySection(
            icon: Icons.lock_outline,
            title: 'Security and retention',
            body:
                'Settings and cached documents use Android private app storage. Keep your phone and local printer network secure. Printer settings remain until you remove them or uninstall the app. Failed print files remain until successfully handled, cleared in the app, removed by Android, or the app is uninstalled.',
          ),
          const _PolicySection(
            icon: Icons.tune_outlined,
            title: 'Your controls',
            body:
                'You can remove saved printers, clear the print-job cache, revoke Bluetooth or USB access in Android settings, disable the Android print service, or uninstall Receipt Bridge to remove its locally stored data.',
          ),
          const _PolicySection(
            icon: Icons.update_outlined,
            title: 'Policy updates',
            body:
                'This policy may be updated when app features or data practices change. The effective date shown above will be updated with material revisions.',
          ),
          const _PolicySection(
            icon: Icons.contact_support_outlined,
            title: 'Privacy contact',
            body:
                'For privacy questions or requests, contact Aung Kyaw Thu through the same app distribution channel or store listing from which you received Receipt Bridge.',
          ),
          const SizedBox(height: 20),
          const Center(
            child: Text(
              'Developed by Aung Kyaw Thu',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Center(
            child: const Text(
              'aungkyawthu.dev@gmail.com',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  const _PolicySection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(body, style: const TextStyle(height: 1.45)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
