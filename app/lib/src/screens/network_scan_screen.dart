import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/label_pickers.dart';
import '../l10n.dart';

/// Scannen an einem Netzwerkscanner (eSCL/AirScan), den der Server ansteuert.
class NetworkScanScreen extends StatefulWidget {
  const NetworkScanScreen({super.key});

  @override
  State<NetworkScanScreen> createState() => _NetworkScanScreenState();
}

class _NetworkScanScreenState extends State<NetworkScanScreen> {
  late Future<List<ScannerInfo>> _scanners;
  ScannerInfo? _selected;
  Future<ScannerCapabilities>? _caps;
  String _source = 'Platen';
  String _color = 'RGB24';
  int _resolution = 300;
  bool _duplex = false;
  final _title = TextEditingController();
  Set<int> _tags = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _load({bool refresh = false}) {
    _scanners = AppScope.read(context).client.scanners(refresh: refresh).then((
      list,
    ) {
      if (list.length == 1 && _selected == null) _select(list.single);
      return list;
    });
  }

  void _select(ScannerInfo s) {
    setState(() {
      _selected = s;
      _caps = AppScope.read(context).client.scannerCapabilities(s.id).then((c) {
        if (mounted) {
          setState(() {
            if (c.sources.isNotEmpty && !c.sources.contains(_source)) {
              _source = c.sources.first;
            }
            if (c.colorModes.isNotEmpty && !c.colorModes.contains(_color)) {
              _color = c.colorModes.first;
            }
            if (c.resolutions.isNotEmpty &&
                !c.resolutions.contains(_resolution)) {
              _resolution = c.resolutions.reduce(
                (a, b) => (a - 300).abs() <= (b - 300).abs() ? a : b,
              );
            }
          });
        }
        return c;
      });
    });
  }

  Future<void> _scan() async {
    final s = _selected;
    if (s == null) return;
    setState(() => _busy = true);
    final state = AppScope.read(context);
    final taskId = await guarded(
      context,
      () => state.client.scan(
        s.id,
        source: _source,
        colorMode: _color,
        resolution: _resolution,
        duplex: _duplex,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
        tags: _tags.toList(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (taskId != null) {
      state.uploads
          .trackTask(state.client, taskId, tr.scanAt(s.name))
          .ignore();
      Navigator.pop(context);
    }
  }

  static String _colorLabel(String mode) => switch (mode) {
    'RGB24' || 'RGB48' => tr.color,
    'Grayscale8' || 'Grayscale16' => tr.grayscale,
    'BlackAndWhite1' => tr.blackAndWhite,
    _ => mode,
  };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.networkScanner),
        actions: [
          IconButton(
            tooltip: tr.searchAgain,
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: () => setState(() => _load(refresh: true)),
          ),
        ],
      ),
      body: FutureBuilder<List<ScannerInfo>>(
        future: _scanners,
        builder: (context, snap) {
          if (snap.hasError) {
            final e = snap.error;
            return EmptyHint(
              icon: LucideIcons.scanLine,
              text: e is ApiException && e.isNotFound
                  ? tr.thisServerDoesNotSupport
                  : tr.couldNotQueryScanners(e is ApiException ? e.message : '$e'),
            );
          }
          final list = snap.data;
          if (list == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (list.isEmpty) {
            return EmptyHint(
              icon: LucideIcons.scanLine,
              text:
                  tr.noScannerFoundTheServer,
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      for (final s in list)
                        Card(
                          color: _selected?.id == s.id
                              ? theme.colorScheme.secondaryContainer
                              : null,
                          child: ListTile(
                            leading: const Icon(LucideIcons.printer),
                            title: Text(s.name),
                            subtitle: Text(
                              s.discovered
                                  ? tr.foundOnTheNetwork
                                  : tr.configured,
                            ),
                            onTap: () => _select(s),
                          ),
                        ),
                      if (_caps != null)
                        FutureBuilder<ScannerCapabilities>(
                          future: _caps,
                          builder: (context, capSnap) {
                            if (capSnap.hasError) {
                              return Text(
                                tr.scannerDoesNotRespond('${capSnap.error}'),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              );
                            }
                            final c = capSnap.data;
                            if (c == null) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              spacing: 12,
                              children: [
                                if (c.makeAndModel.isNotEmpty)
                                  Text(
                                    c.makeAndModel,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                if (c.sources.length > 1)
                                  SegmentedButton<String>(
                                    segments: [
                                      for (final src in c.sources)
                                        ButtonSegment(
                                          value: src,
                                          label: Text(
                                            src == 'Feeder' ? tr.feeder : tr.flatbed,
                                          ),
                                        ),
                                    ],
                                    selected: {_source},
                                    onSelectionChanged: (v) =>
                                        setState(() => _source = v.first),
                                  ),
                                if (c.colorModes.isNotEmpty)
                                  DropdownButtonFormField<String>(
                                    initialValue: _color,
                                    decoration: InputDecoration(
                                      labelText: tr.color,
                                    ),
                                    items: [
                                      for (final m in c.colorModes)
                                        DropdownMenuItem(
                                          value: m,
                                          child: Text(_colorLabel(m)),
                                        ),
                                    ],
                                    onChanged: (v) =>
                                        setState(() => _color = v ?? _color),
                                  ),
                                if (c.resolutions.isNotEmpty)
                                  DropdownButtonFormField<int>(
                                    initialValue: _resolution,
                                    decoration: InputDecoration(
                                      labelText: tr.resolution,
                                    ),
                                    items: [
                                      for (final r in c.resolutions)
                                        DropdownMenuItem(
                                          value: r,
                                          child: Text('$r dpi'),
                                        ),
                                    ],
                                    onChanged: (v) => setState(
                                      () => _resolution = v ?? _resolution,
                                    ),
                                  ),
                                if (c.duplex && _source == 'Feeder')
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(tr.duplex),
                                    value: _duplex,
                                    onChanged: (v) =>
                                        setState(() => _duplex = v),
                                  ),
                                TextField(
                                  controller: _title,
                                  decoration: InputDecoration(
                                    labelText: tr.titleOptional,
                                  ),
                                ),
                                TagsField(
                                  tags: state.tags,
                                  selected: _tags,
                                  onChanged: (v) => setState(() => _tags = v),
                                ),
                                FilledButton.icon(
                                  onPressed: _busy ? null : _scan,
                                  icon: _busy
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(LucideIcons.scanLine),
                                  label: Text(_busy ? tr.scanning : tr.scan),
                                ),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
