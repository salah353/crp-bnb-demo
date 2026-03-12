import 'dart:async';
import 'dart:convert';

import 'package:crp_sdk/crp_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: "assets/.env");
  runApp(const CrpBnbDemoApp());
}

class AppConfig {
  static String get apiBaseUrl =>
      (dotenv.env['CRP_API_BASE_URL'] ?? 'http://167.86.102.165:5001').trim();

  static String get apiKey => (dotenv.env['CRP_API_KEY'] ?? '').trim();
}

class CrpBnbDemoApp extends StatelessWidget {
  const CrpBnbDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CRP BNB Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
      home: const CrpBnbDemoHome(),
    );
  }
}

class _Keys {
  static const bnbMnemonic = 'bnb_mnemonic';
  static const bnbPrivateKey = 'bnb_private_key';
  static const bnbAddress = 'bnb_address';
}

class CrpBnbDemoHome extends StatefulWidget {
  const CrpBnbDemoHome({super.key});

  @override
  State<CrpBnbDemoHome> createState() => _CrpBnbDemoHomeState();
}

class _CrpBnbDemoHomeState extends State<CrpBnbDemoHome> {
  final _secure = const FlutterSecureStorage();

  final _toCtrl = TextEditingController();
  final _amountCtrl = TextEditingController(text: '0.01');

  String? _address;
  String? _privateKey;
  bool _showKeys = false;

  bool _busy = false;
  TransferResult? _lastResult;

  final _logs = <String>[];
  bool _logsExpanded = false;

  bool _balBusy = false;
  BigInt _balBnb = BigInt.zero;   // 18 decimals
  BigInt _balUsdt = BigInt.zero;  // usually 18 on BNB, verify in your backend

  @override
  void initState() {
    super.initState();
    _loadWallet();
  }

  @override
  void dispose() {
    _toCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  String _shortAddr(String s, {int head = 6, int tail = 4}) {
    if (s.length <= head + tail) return s;
    return '${s.substring(0, head)}…${s.substring(s.length - tail)}';
  }

  Widget _tokenBadge(String sym) {
    final bg = switch (sym) {
      'USDT' => const Color(0xFF38B47B),
      'BNB' => const Color(0xFFF0B90B),
      _ => const Color(0xFF90A4AE),
    };

    final icon = switch (sym) {
      'USDT' => Icons.toll,
      'BNB' => Icons.currency_bitcoin,
      _ => Icons.circle,
    };

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: bg.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: bg.withOpacity(0.35)),
      ),
      child: Icon(icon, color: bg, size: 18),
    );
  }

  Widget _pillButton({required Widget child, required VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.65),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
        ),
        child: child,
      ),
    );
  }

  BoxDecoration _cardDeco() => BoxDecoration(
    color: Colors.white.withOpacity(0.72),
    borderRadius: BorderRadius.circular(22),
    border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
    boxShadow: [
      BoxShadow(
        blurRadius: 18,
        offset: const Offset(0, 8),
        color: Colors.black.withOpacity(0.06),
      ),
    ],
  );

  void _log(String m) {
    setState(() {
      _logs.add('${DateTime.now().toIso8601String().substring(11, 19)} $m');
    });
  }

  Future<void> _loadWallet() async {
    final addr = await _secure.read(key: _Keys.bnbAddress);
    final pk = await _secure.read(key: _Keys.bnbPrivateKey);
    if (addr != null && pk != null) {
      setState(() {
        _address = addr;
        _privateKey = pk;
      });
      _log('Wallet loaded from secure storage.');
      await _fetchBalances();
    }
  }

  Future<void> _generateWallet() async {
    setState(() => _busy = true);
    try {
      final mnemonic = MnemonicService.generate();
      _log('Generated new mnemonic.');
      await _deriveAndSave(mnemonic);
    } catch (e) {
      _log('Error generating wallet: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _showImportDialog() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Seed Phrase'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'Enter 12-word mnemonic...',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _importWallet(ctrl.text);
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  Future<void> _importWallet(String mnemonic) async {
    if (mnemonic.trim().split(RegExp(r'\s+')).length < 12) {
      _log('Invalid mnemonic length.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _deriveAndSave(mnemonic);
      _log('Wallet imported successfully.');
    } catch (e) {
      _log('Error importing wallet: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _deriveAndSave(String mnemonic) async {
    // IMPORTANT:
    // Replace this call with the actual BNB/EVM wallet restore method exposed by your SDK.
    // Example guesses:
    // final wallet = await EvmWalletService.restoreWallet(mnemonic: mnemonic);
    // final wallet = await BnbWalletService.restoreWallet(mnemonic: mnemonic);

    final wallet = await EvmWalletService.restoreWallet(mnemonic: mnemonic);

    final addr = wallet['address'] as String;
    final pk = wallet['privateKey'] as String;

    await _secure.write(key: _Keys.bnbMnemonic, value: mnemonic);
    await _secure.write(key: _Keys.bnbAddress, value: addr);
    await _secure.write(key: _Keys.bnbPrivateKey, value: pk);

    setState(() {
      _address = addr;
      _privateKey = pk;
      _lastResult = null;
    });

    _log('Derived BNB address: $addr');
    await _fetchBalances();
  }

  Future<void> _clearWallet() async {
    await _secure.deleteAll();
    setState(() {
      _address = null;
      _privateKey = null;
      _lastResult = null;
      _logs.clear();
      _balBnb = BigInt.zero;
      _balUsdt = BigInt.zero;
      _showKeys = false;
    });
  }

  bool get _hasAnyNonZeroBalance =>
      _balBnb > BigInt.zero || _balUsdt > BigInt.zero;

  String _formatAmount(BigInt raw, int decimals) {
    if (raw == BigInt.zero) return '0';
    final neg = raw.isNegative;
    final v = neg ? -raw : raw;
    final base = BigInt.from(10).pow(decimals);
    final whole = v ~/ base;
    final frac = (v % base).toString().padLeft(decimals, '0');
    final fracTrim = frac.replaceFirst(RegExp(r'0+$'), '');
    final s = fracTrim.isEmpty ? '$whole' : '$whole.$fracTrim';
    return neg ? '-$s' : s;
  }

  Future<void> _fetchBalances() async {
    if (_address == null || _privateKey == null) return;
    setState(() => _balBusy = true);
    try {
      final bnb = await _fetchBalanceRemote('Bnb', 'BNB');
      final usdt = await _fetchBalanceRemote('Bnb', 'USDT');

      setState(() {
        _balBnb = bnb;
        _balUsdt = usdt;
      });
      _log('Balances refreshed.');
    } catch (e) {
      _log('Error fetching balances: $e');
    } finally {
      setState(() => _balBusy = false);
    }
  }

  Future<BigInt> _fetchBalanceRemote(String chain, String symbol) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/wallets/balance').replace(
      queryParameters: {
        'chain': chain,
        'address': _address!,
        'symbol': symbol,
      },
    );

    final headers = {
      'Accept': 'application/json',
      if (AppConfig.apiKey.isNotEmpty) 'X-API-KEY': AppConfig.apiKey,
    };

    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) {
      throw Exception('API Error (${response.statusCode}): ${response.body}');
    }
    final data = jsonDecode(response.body);
    return BigInt.parse(data['balance'].toString());
  }

  Future<void> _send() async {
    if (_address == null || _privateKey == null) return;

    setState(() {
      _busy = true;
      _lastResult = null;
    });

    _log('Starting BNB transfer...');

    try {
      final to = _toCtrl.text.trim();
      final amountStr = _amountCtrl.text.trim();

      if (to.isEmpty) throw Exception('Recipient address required');
      if (amountStr.isEmpty) throw Exception('Amount required');

      // IMPORTANT:
      // Verify token decimals for BNB USDT in your API/SDK.
      // Most BEP-20 USDT uses 18 decimals, but do not assume blindly.
      const tokenDecimals = 18;

      final parts = amountStr.split('.');
      final whole = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
      BigInt frac = BigInt.zero;
      if (parts.length > 1) {
        final f = parts[1].padRight(tokenDecimals, '0').substring(0, tokenDecimals);
        frac = BigInt.parse(f.isEmpty ? '0' : f);
      }
      final amountRaw = whole * BigInt.from(10).pow(tokenDecimals) + frac;
      if (amountRaw <= BigInt.zero) throw Exception('Amount must be > 0');

      final apiClient = ExampleApiClient(
        baseUrl: AppConfig.apiBaseUrl,
        apiKey: AppConfig.apiKey.isEmpty ? null : AppConfig.apiKey,
      );

      final sdk = CrpSdk(
        apiClient: apiClient,
        privateKeys: {Chain.bsc: _privateKey!},
        addresses: {Chain.bsc: _address!},
      );

      final result = await sdk.sendTransfer(
        chain: Chain.bsc,
        token: Token.usdt,
        to: to,
        amount: amountRaw,
        clientIdempotencyKey: DateTime.now().millisecondsSinceEpoch.toString(),
      );

      setState(() => _lastResult = result);

      if (result.intent.txHash != null) {
        _log('Broadcast success: ${result.intent.txHash}');
      } else {
        _log('Transfer status: ${result.intent.status.name}');
      }

      await _fetchBalances();
    } catch (e) {
      _log('Error sending: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied!')),
    );
  }

  void _openExplorer(String tx) {
    _log('Explorer Link: https://bscscan.com/tx/$tx');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CRP BNB Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_address == null) _buildSetupCard() else _buildSendCard(),
          if (_lastResult != null) ...[
            const SizedBox(height: 12),
            _buildCompactResultCard(),
          ],
          const SizedBox(height: 12),
          if (_address != null) _buildWalletCardStyled(),
          const SizedBox(height: 12),
          _buildLogPanelStyled(),
        ],
      ),
    );
  }

  Widget _buildSetupCard() {
    return Container(
      decoration: _cardDeco(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Wallet Setup',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            'No wallet found. Generate a new one or import an existing seed phrase.',
            style: TextStyle(color: Colors.blueGrey.shade600),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _generateWallet,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Generate Wallet'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _showImportDialog,
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('Import Seed'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSendCard() {
    final availUsdt = _formatAmount(_balUsdt, 18);

    return Container(
      decoration: _cardDeco(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Send', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(
            'Available: $availUsdt USDT',
            style: TextStyle(color: Colors.blueGrey.shade400, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.65),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _toCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Recipient BNB address',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _pillButton(
                  onTap: () async {
                    final data = await Clipboard.getData('text/plain');
                    final t = (data?.text ?? '').trim();
                    if (t.isNotEmpty) setState(() => _toCtrl.text = t);
                  },
                  child: const Text('Paste', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 10),
                _pillButton(
                  onTap: null,
                  child: const Icon(Icons.qr_code_scanner, size: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount (USDT)',
              hintText: '0.01',
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              onPressed: _busy ? null : _send,
              child: _busy
                  ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
                  : const Text(
                'Send',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactResultCard() {
    final res = _lastResult!;
    final intent = res.intent;
    final tx = intent.txHash;

    final isSuccess = tx != null && tx.isNotEmpty;
    final status = intent.status.name.toUpperCase();
    final color = isSuccess ? Colors.green : Colors.orange;

    final amountShown = _amountCtrl.text.trim().isEmpty ? '' : _amountCtrl.text.trim();

    return Container(
      decoration: _cardDeco(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isSuccess ? Icons.check_circle : Icons.schedule, color: color),
              const SizedBox(width: 10),
              Text(
                '${status[0]}${status.substring(1).toLowerCase()}',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color),
              ),
              if (amountShown.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text('• $amountShown USDT', style: TextStyle(color: Colors.blueGrey.shade600)),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (tx != null && tx.isNotEmpty) ...[
            Text(
              'Tx: ${_shortAddr(tx, head: 12, tail: 8)}',
              style: TextStyle(color: Colors.blueGrey.shade600),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _openExplorer(tx),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('View on Explorer'),
            ),
          ] else ...[
            Text(
              'Intent: ${_shortAddr(intent.intentId, head: 10, tail: 8)}',
              style: TextStyle(color: Colors.blueGrey.shade600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWalletCardStyled() {
    final addr = _address ?? '';

    return Container(
      decoration: _cardDeco(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Wallet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.amber.withOpacity(0.30)),
                ),
                child: const Text(
                  'BNB Mainnet',
                  style: TextStyle(
                    color: Color(0xFF8A6A00),
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_hasAnyNonZeroBalance)
            Text('No balances.', style: TextStyle(color: Colors.blueGrey.shade400))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_balBnb > BigInt.zero) _balanceChip('BNB', _formatAmount(_balBnb, 18)),
                if (_balUsdt > BigInt.zero) _balanceChip('USDT', _formatAmount(_balUsdt, 18)),
              ],
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.65),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
            ),
            child: Row(
              children: [
                _tokenBadge('BNB'),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _shortAddr(addr, head: 10, tail: 6),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _copyToClipboard(addr),
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Non-custodial • BNB Chain',
            style: TextStyle(color: Colors.blueGrey.shade400, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.65),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showKeys = !_showKeys),
                    icon: Icon(_showKeys ? Icons.visibility_off : Icons.visibility, size: 18),
                    label: Text(_showKeys ? 'Hide' : 'Show'),
                  ),
                ),
                Container(width: 1, height: 26, color: Colors.blueGrey.withOpacity(0.12)),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _balBusy ? null : _fetchBalances,
                    icon: _balBusy
                        ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh'),
                  ),
                ),
                Container(width: 1, height: 26, color: Colors.blueGrey.withOpacity(0.12)),
                Expanded(
                  child: TextButton.icon(
                    onPressed: _clearWallet,
                    icon: Icon(Icons.delete_forever, size: 18, color: Colors.red.shade900),
                    label: Text('Wallet', style: TextStyle(color: Colors.red.shade900)),
                  ),
                ),
              ],
            ),
          ),
          if (_showKeys) ...[
            const SizedBox(height: 12),
            const Text(
              'Private Key',
              style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            SelectableText(
              _privateKey ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _balanceChip(String sym, String amount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
      ),
      child: Text(
        '$sym $amount',
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildLogPanelStyled() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.blueGrey.withOpacity(0.12)),
      ),
      child: ExpansionTile(
        title: const Text('Logs', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
        initiallyExpanded: _logsExpanded,
        onExpansionChanged: (exp) => setState(() => _logsExpanded = exp),
        children: [
          Container(
            height: 170,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.blueGrey.withOpacity(0.04),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                _logs.isEmpty ? 'No logs yet.' : _logs.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}