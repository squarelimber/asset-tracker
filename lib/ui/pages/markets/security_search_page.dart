import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/responsive.dart';
import '../../../services/market/security_search_source.dart';
import '../../components/error_state.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

class SecuritySearchPage extends StatefulWidget {
  const SecuritySearchPage({super.key, this.source});

  final SecuritySearchSource? source;

  @override
  State<SecuritySearchPage> createState() => _SecuritySearchPageState();
}

class _SecuritySearchPageState extends State<SecuritySearchPage> {
  final _controller = TextEditingController();
  late final SecuritySearchSource _source;
  Timer? _debounce;
  int _requestId = 0;
  bool _loading = false;
  bool _failed = false;
  List<SecuritySearchResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? SecuritySearchSource();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    if (widget.source == null) _source.close();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    final query = value.trim();
    final request = ++_requestId;
    setState(() {
      _failed = false;
      _results = const [];
      _loading = query.isNotEmpty;
    });
    if (query.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _search(query, request);
    });
  }

  Future<void> _search(String query, int request) async {
    try {
      final results = await _source.search(query);
      if (!mounted || request != _requestId) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _requestId) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索股票和 ETF')),
      body: ResponsiveShell(
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _changed,
              decoration: InputDecoration(
                hintText: '输入名称、代码或拼音',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '清空搜索',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _controller.clear();
                    _changed('');
                  },
                ),
              ),
            ),
            const SizedBox(height: T.s3),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_controller.text.trim().isEmpty) {
      return const Center(child: Text('搜索 A 股、港股、美股及 ETF'));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return ErrorState(
        message: '搜索失败，请检查网络后重试',
        onRetry: () => _changed(_controller.text),
      );
    }
    if (_results.isEmpty) return const Center(child: Text('未找到匹配的股票或 ETF'));
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        return TerminalCard(
          margin: const EdgeInsets.only(bottom: T.s2),
          padding: EdgeInsets.zero,
          child: ListTile(
            title: Text(
              result.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${result.code} · ${result.market} · ${result.type}',
              style: T.label(),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(
              Uri(
                path: '/markets/kline',
                queryParameters: {'symbol': result.symbol, 'name': result.name},
              ).toString(),
            ),
          ),
        );
      },
    );
  }
}
