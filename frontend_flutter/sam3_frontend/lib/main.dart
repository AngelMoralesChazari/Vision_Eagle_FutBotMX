// ============================================================================
//  SAM3 · Editor de Video — Paso 3a
//  Conecta al backend (ngrok), carga un video, lo envía por WebSocket,
//  muestra una barra de progreso y resume las capas recibidas.
//  (El reproductor de video y el panel completo llegan en 3b y 3c.)
//
//  Dependencias (ya las tienes en pubspec.yaml):
//    file_picker: ^8.x
//    web_socket_channel: ^3.x
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:web_socket_channel/io.dart';
import 'models.dart';
import 'field_screen.dart';

void main() => runApp(const SamEditorApp());

class SamEditorApp extends StatelessWidget {
  const SamEditorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SAM3 · Editor de Video',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const EditorScreen(),
    );
  }
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _urlCtrl = TextEditingController();
  final _promptCtrl = TextEditingController();

  IOWebSocketChannel? _channel;
  bool _connected = false;
  String _status = 'Sin conectar';

  // Video cargado
  String? _videoName;
  Uint8List? _videoBytes;

  // Parámetro de "presencia mínima" (cuántos frames debe aparecer un objeto
  // para contar como capa). 0.5 nos dio 4 capas limpias en las pruebas.
  double _minPresence = 0.5;

  // fps de procesamiento (menos fps = menos frames = más rápido).
  double _fps = 4;

  // Vista previa: procesar solo los primeros N segundos.
  bool _previewOnly = false;
  double _previewSecs = 10;

  // Procesamiento / recepción
  bool _processing = false;
  String _phase = 'idle';   // idle | processing | receiving | done
  int _done = 0;
  int _total = 0;
  int _received = 0;

  // Resultado del backend
  Map<String, dynamic>? _result;          // metadata: width, height, objects...
  final List<String> _bases = [];         // frame original (jpg base64) por frame
  final List<ui.Image?> _baseImgs = [];   // frame original YA decodificado
  final List<List<FrameObj>> _frameObjs = []; // objetos presentes por frame
  List<LayerView> _layers = [];           // capas con estilo editable
  final Map<int, TextEditingController> _nameCtrls = {};  // renombrar por capa

  // Reproductor
  int _playIndex = 0;
  bool _playing = false;
  Timer? _playTimer;

  // Exportar / descargar
  bool _exporting = false;
  final StringBuffer _exportBuf = StringBuffer();

  // Modo cine (oculta los controles para agrandar el lienzo)
  bool _compact = false;

  // --------------------------------------------------------------------------
  //  Conexión
  // --------------------------------------------------------------------------
  void _connect() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _status = 'Pega la URL de ngrok primero');
      return;
    }
    // https://xxxx.ngrok-free.dev  ->  wss://xxxx.ngrok-free.dev/ws
    var wsUrl = url
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    if (!wsUrl.endsWith('/ws')) wsUrl = '$wsUrl/ws';

    try {
      final ch = IOWebSocketChannel.connect(
        Uri.parse(wsUrl),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );
      ch.stream.listen(_onMessage, onDone: _onDone, onError: _onError);
      setState(() {
        _channel = ch;
        _connected = true;
        _status = 'Conectado ✅';
      });
    } catch (e) {
      setState(() {
        _connected = false;
        _status = 'Error al conectar: $e';
      });
    }
  }

  void _onDone() {
    setState(() {
      _connected = false;
      _processing = false;
      _status = 'Conexión cerrada';
    });
  }

  void _onError(Object e) {
    setState(() {
      _connected = false;
      _processing = false;
      _status = 'Error de conexión: $e';
    });
  }

  // --------------------------------------------------------------------------
  //  Mensajes entrantes del backend
  // --------------------------------------------------------------------------
  void _onMessage(dynamic message) {
    final msg = jsonDecode(message as String) as Map<String, dynamic>;
    final type = msg['type'];

    if (type == 'video_ack') {
      // el backend confirmó que recibe la carga; nada que hacer
    } else if (type == 'prompts') {
      final pairs = (msg['pairs'] as List);
      final shown = pairs
          .map((p) => '${(p as List)[0]} → ${p[1]}')
          .join(' · ');
      setState(() => _status = 'Traducido: $shown');
    } else if (type == 'video_info') {
      setState(() {
        _total = msg['n_frames'] as int;
        _phase = 'processing';
        _status = 'Procesando ${msg['n_frames']} frames a ${msg['proc_fps']} fps…';
      });
    } else if (type == 'progress') {
      setState(() {
        _done = msg['done'] as int;
        _total = msg['total'] as int;
      });
    } else if (type == 'result_meta') {
      setState(() {
        _result = msg;
        _bases.clear();
        _baseImgs.clear();
        _frameObjs.clear();
        _received = 0;
        _playIndex = 0;
        _phase = 'receiving';
        for (final c in _nameCtrls.values) {
          c.dispose();
        }
        _nameCtrls.clear();
        _layers = (msg['objects'] as List).map((o) {
          final c = (o['color'] as List).cast<int>();
          final tr = (o['trail'] as List)
              .map((p) => (
                    (p[0] as num).toInt(),
                    Offset((p[1] as num).toDouble(), (p[2] as num).toDouble()),
                  ))
              .toList();
          final lv = LayerView(
            id: o['id'] as int,
            color: Color.fromARGB(255, c[0], c[1], c[2]),
            trail: tr,
            label: o['label'] as String,
          );
          _nameCtrls[lv.id] = TextEditingController(text: lv.name);
          return lv;
        }).toList();
        _status = 'Recibiendo… (${_layers.length} capas)';
      });
    } else if (type == 'frame') {
      final fi = _bases.length;
      final baseB64 = msg['base_jpg'] as String;
      final objs = (msg['objects'] as List)
          .map((o) => FrameObj(
                o['id'] as int,
                (o['bbox'] as List).map((v) => (v as num).toDouble()).toList(),
                o['mask_png'] as String,
              ))
          .toList();
      setState(() {
        _bases.add(baseB64);
        _baseImgs.add(null);
        _frameObjs.add(objs);
        _received = _bases.length;
      });
      // Decodificar cada imagen UNA sola vez (asíncrono). Cuando llegan, se
      // dibujan sincronizadas en el lienzo; nunca se re-decodifican al reproducir.
      _decodeImg(baseB64).then((img) {
        if (!mounted || fi >= _baseImgs.length) return;
        setState(() => _baseImgs[fi] = img);
      });
      for (final fo in objs) {
        _decodeImg(fo.mask).then((img) {
          if (!mounted) return;
          setState(() => fo.maskImg = img);
        });
      }
    } else if (type == 'result_done') {
      setState(() {
        _processing = false;
        _phase = 'done';
        final n = _result != null ? (_result!['objects'] as List).length : 0;
        _status = '✅ Listo: $n capas, $_received frames';
      });
    } else if (type == 'export_start') {
      _exportBuf.clear();
      setState(() {
        _exporting = true;
        _status = 'Preparando descarga…';
      });
    } else if (type == 'export_chunk') {
      _exportBuf.write(msg['data'] as String);
    } else if (type == 'export_end') {
      _saveExport();
    } else if (type == 'error') {
      setState(() {
        _processing = false;
        _phase = 'idle';
        _status = '❌ ${msg['msg']}';
      });
    }
  }

  // Decodifica un PNG/JPEG base64 a una ui.Image (una sola vez por imagen).
  Future<ui.Image> _decodeImg(String b64) async {
    final codec = await ui.instantiateImageCodec(base64Decode(b64));
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  // --------------------------------------------------------------------------
  //  Cargar video
  // --------------------------------------------------------------------------
  Future<void> _pickVideo() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;

    Uint8List? bytes = f.bytes;
    if (bytes == null && f.path != null) {
      bytes = await File(f.path!).readAsBytes();
    }
    if (bytes == null) {
      setState(() => _status = 'No se pudo leer el video');
      return;
    }
    setState(() {
      _videoName = f.name;
      _videoBytes = bytes;
      _result = null;
      _status = 'Video cargado: ${f.name} (${(bytes!.length / 1024 / 1024).toStringAsFixed(1)} MB)';
    });
  }

  // --------------------------------------------------------------------------
  //  Procesar (enviar al backend)
  // --------------------------------------------------------------------------
  void _process() {
    if (_channel == null || !_connected) {
      setState(() => _status = 'Conéctate al backend primero');
      return;
    }
    if (_videoBytes == null) {
      setState(() => _status = 'Carga un video primero');
      return;
    }
    if (_promptCtrl.text.trim().isEmpty) {
      setState(() => _status = 'Escribe qué rastrear (ej. person)');
      return;
    }

    final b64 = base64Encode(_videoBytes!);
    setState(() {
      _processing = true;
      _phase = 'processing';
      _done = 0;
      _total = 0;
      _received = 0;
      _result = null;
      _frameObjs.clear();
      _bases.clear();
      _playIndex = 0;
      _playing = false;
      _playTimer?.cancel();
      _status = 'Enviando video…';
    });

    // Enviar en pedacitos (chunks) para no atragantar el túnel de ngrok.
    const chunkSize = 256 * 1024; // 256 KB por mensaje
    _channel!.sink.add(jsonEncode({
      'type': 'video_start',
      'prompt': _promptCtrl.text.trim(),
      'min_presence': _minPresence,
      'target_fps': _fps,
      if (_previewOnly) 'max_seconds': _previewSecs,
    }));
    for (int i = 0; i < b64.length; i += chunkSize) {
      final end = (i + chunkSize < b64.length) ? i + chunkSize : b64.length;
      _channel!.sink.add(jsonEncode({
        'type': 'video_chunk',
        'data': b64.substring(i, end),
      }));
    }
    _channel!.sink.add(jsonEncode({'type': 'video_end'}));
    setState(() => _status = 'Procesando…');
  }

  // --------------------------------------------------------------------------
  //  Reproductor
  // --------------------------------------------------------------------------
  void _togglePlay() {
    if (_playing) {
      _playTimer?.cancel();
      setState(() => _playing = false);
      return;
    }
    if (_bases.isEmpty) return;
    final fps = ((_result?['proc_fps'] ?? 4) as num).toDouble();
    final ms = (1000 / (fps <= 0 ? 4 : fps)).round();
    setState(() => _playing = true);
    _playTimer = Timer.periodic(Duration(milliseconds: ms), (t) {
      setState(() {
        _playIndex++;
        if (_playIndex >= _bases.length) _playIndex = 0; // loop
      });
    });
  }

  // --------------------------------------------------------------------------
  //  Descargar el video segmentado
  // --------------------------------------------------------------------------
  void _exportVideo() {
    if (_channel == null || !_connected) {
      setState(() => _status = 'Conéctate al backend primero');
      return;
    }
    if (_bases.isEmpty) {
      setState(() => _status = 'Procesa un video primero');
      return;
    }
    setState(() {
      _exporting = true;
      _status = 'Pidiendo el video al backend…';
    });
    _channel!.sink.add(jsonEncode({'type': 'export_video'}));
  }

  Future<void> _saveExport() async {
    final bytes = base64Decode(_exportBuf.toString());
    _exportBuf.clear();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar video segmentado',
      fileName: 'segmentado.mp4',
      type: FileType.custom,
      allowedExtensions: ['mp4'],
    );
    if (path == null) {
      setState(() {
        _exporting = false;
        _status = 'Descarga cancelada';
      });
      return;
    }
    final p = path.toLowerCase().endsWith('.mp4') ? path : '$path.mp4';
    await File(p).writeAsBytes(bytes);
    setState(() {
      _exporting = false;
      _status = '✅ Guardado: $p';
    });
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    for (final c in _nameCtrls.values) {
      c.dispose();
    }
    _channel?.sink.close();
    _urlCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  //  UI
  // --------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SAM3 · Editor de Video'),
        actions: [
          if (_phase == 'done' && _layers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _openField,
                icon: const Icon(Icons.stadium),
                label: const Text('Cancha 2D'),
              ),
            ),
          IconButton(
            tooltip: _compact ? 'Mostrar controles' : 'Modo cine (lienzo grande)',
            icon: Icon(_compact ? Icons.tune : Icons.fullscreen),
            onPressed: () => setState(() => _compact = !_compact),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(children: [
              Icon(Icons.circle,
                  size: 12, color: _connected ? Colors.green : Colors.red),
              const SizedBox(width: 6),
              Text(_connected ? 'Conectado' : 'Sin conexión'),
            ]),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Controles de configuración (se ocultan en modo cine) ---
            if (!_compact) ...[
            // --- Barra de conexión ---
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'URL de ngrok',
                    hintText: 'https://xxxx.ngrok-free.dev',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.link),
                label: const Text('Conectar'),
              ),
            ]),
            const SizedBox(height: 20),

            // --- Cargar video ---
            Row(children: [
              OutlinedButton.icon(
                onPressed: _processing ? null : _pickVideo,
                icon: const Icon(Icons.video_file),
                label: const Text('Cargar video'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _videoName ?? 'Ningún video cargado',
                  style: TextStyle(color: Colors.grey[400]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            const SizedBox(height: 12),

            // --- Prompt + Procesar ---
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _promptCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Qué rastrear (separa con comas)',
                    hintText: 'small robot, orange ball',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _processing ? null : _process,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Procesar'),
              ),
            ]),
            const SizedBox(height: 12),

            // --- Presencia mínima ---
            Row(children: [
              const Text('Presencia mín.:'),
              Expanded(
                child: Slider(
                  value: _minPresence,
                  min: 0.1,
                  max: 0.7,
                  divisions: 12,
                  label: _minPresence.toStringAsFixed(2),
                  onChanged: _processing
                      ? null
                      : (v) => setState(() => _minPresence = v),
                ),
              ),
              Text(_minPresence.toStringAsFixed(2)),
            ]),
            const SizedBox(height: 4),

            // --- fps de procesamiento ---
            Row(children: [
              const Text('fps de proceso:'),
              Expanded(
                child: Slider(
                  value: _fps,
                  min: 1,
                  max: 12,
                  divisions: 11,
                  label: '${_fps.round()} fps',
                  onChanged: _processing
                      ? null
                      : (v) => setState(() => _fps = v),
                ),
              ),
              Text('${_fps.round()} fps'),
            ]),
            Text(
              'Menos fps = procesa más rápido pero el rastreo se ve a saltos. '
              'Para videos largos, 3-6 fps es buen punto.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),

            // --- Vista previa (solo los primeros N segundos) ---
            Row(children: [
              Switch(
                value: _previewOnly,
                onChanged: _processing
                    ? null
                    : (v) => setState(() => _previewOnly = v),
              ),
              const SizedBox(width: 4),
              const Text('Solo vista previa'),
              const SizedBox(width: 12),
              if (_previewOnly) ...[
                Expanded(
                  child: Slider(
                    value: _previewSecs,
                    min: 3,
                    max: 30,
                    divisions: 27,
                    label: '${_previewSecs.round()} s',
                    onChanged: _processing
                        ? null
                        : (v) => setState(() => _previewSecs = v),
                  ),
                ),
                Text('${_previewSecs.round()} s'),
              ] else
                Expanded(
                  child: Text(
                    'procesa el video completo',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ),
            ]),
            const SizedBox(height: 16),
            ], // fin del bloque de controles (modo cine)

            // --- Progreso (dos fases: procesar, luego recibir overlays) ---
            if (_phase == 'processing') ...[
              LinearProgressIndicator(value: _total > 0 ? _done / _total : null),
              const SizedBox(height: 8),
              Text('Procesando: $_done / $_total frames'),
              const SizedBox(height: 16),
            ] else if (_phase == 'receiving') ...[
              LinearProgressIndicator(value: _total > 0 ? _received / _total : null),
              const SizedBox(height: 8),
              Text('Recibiendo overlays: $_received / $_total'),
              const SizedBox(height: 16),
            ],

            // --- Estado ---
            Text(_status, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 12),

            // --- Reproductor + panel de capas ---
            if (_bases.isNotEmpty)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildPlayer()),
                    const SizedBox(width: 12),
                    SizedBox(width: 240, child: _buildResultSummary()),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Reproductor
  // --------------------------------------------------------------------------
  LayerView? _layerById(int id) {
    for (final L in _layers) {
      if (L.id == id) return L;
    }
    return null;
  }

  // Objetos a mostrar en el frame idx: SOLO los detectados en ESTE frame.
  // La máscara va exactamente donde la detección la pone (ni se atrasa ni se
  // adelanta). Si no hay detección, no se dibuja la máscara ese frame.
  List<FrameObj> _effective(int idx) {
    if (idx < 0 || idx >= _frameObjs.length) return const [];
    return _frameObjs[idx];
  }

  void _openField() {
    final w = ((_result?['width'] ?? 16) as num).toDouble();
    final h = ((_result?['height'] ?? 9) as num).toDouble();
    final frames = _bases.isNotEmpty
        ? _bases.length
        : ((_result?['n_frames'] ?? 1) as num).toInt();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          FieldScreen(layers: _layers, imgW: w, imgH: h, frameCount: frames),
    ));
  }

  Widget _buildPlayer() {
    final idx = _playIndex.clamp(0, _bases.length - 1);
    final w = ((_result?['width'] ?? 16) as num).toDouble();
    final h = ((_result?['height'] ?? 9) as num).toDouble();
    final eff = idx < _frameObjs.length ? _effective(idx) : <FrameObj>[];
    final baseImg = idx < _baseImgs.length ? _baseImgs[idx] : null;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: w / h,
              // UN SOLO lienzo: el frame y las máscaras (ya decodificados) se
              // pintan juntos en el mismo instante -> imposible que se desfasen.
              // El color/visibilidad/caja se aplican aquí al pintar.
              child: CustomPaint(
                size: Size.infinite,
                painter: CanvasPainter(
                  baseImg: baseImg,
                  layers: _layers,
                  present: eff,
                  vw: w,
                  vh: h,
                  currentFrame: idx,
                ),
              ),
            ),
          ),
        ),
        Row(children: [
          IconButton(
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: _togglePlay,
          ),
          Expanded(
            child: Slider(
              value: idx.toDouble(),
              min: 0,
              max: (_bases.length - 1).toDouble().clamp(0, double.infinity),
              onChanged: (v) {
                _playTimer?.cancel();
                setState(() {
                  _playing = false;
                  _playIndex = v.round();
                });
              },
            ),
          ),
          Text('${idx + 1}/${_bases.length}'),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _exporting ? null : _exportVideo,
            icon: const Icon(Icons.download),
            label: Text(_exporting ? 'Descargando…' : 'Descargar'),
          ),
        ]),
      ],
    );
  }

  Widget _buildResultSummary() {
    final idx = _playIndex.clamp(0, (_bases.length - 1).clamp(0, 1 << 30));
    final presentIds = idx < _frameObjs.length
        ? _effective(idx).map((fo) => fo.id).toSet()
        : <int>{};
    final visibles = _layers.where((L) => presentIds.contains(L.id)).toList();
    return Card(
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Capas en este frame',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (visibles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('— ninguna —', style: TextStyle(color: Colors.grey)),
            ),
          ...visibles.map(_buildLayerTile),
        ],
      ),
    );
  }

  Widget _buildLayerTile(LayerView L) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(radius: 12, backgroundColor: L.color),
      title: Text(L.name, style: const TextStyle(fontSize: 14)),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: [
        // Renombrar
        TextField(
          controller: _nameCtrls[L.id],
          decoration: const InputDecoration(
            labelText: 'Nombre', isDense: true, border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => L.name = v),
        ),
        const SizedBox(height: 8),

        // Visible (mostrar/ocultar la segmentación)
        Row(children: [
          const Text('Visible'),
          const Spacer(),
          Switch(
            value: L.maskVisible,
            onChanged: (v) => setState(() => L.maskVisible = v),
          ),
        ]),

        // Mostrar como caja en vez de máscara
        Row(children: [
          const Text('Mostrar como caja'),
          const Spacer(),
          Switch(
            value: L.boxMode,
            onChanged: (v) => setState(() => L.boxMode = v),
          ),
        ]),

        // Mostrar/ocultar rastro
        Row(children: [
          const Text('Rastro'),
          const Spacer(),
          Switch(
            value: L.showTrail,
            onChanged: (v) => setState(() => L.showTrail = v),
          ),
        ]),

        // Mostrar/ocultar etiqueta
        Row(children: [
          const Text('Etiqueta'),
          const Spacer(),
          Switch(
            value: L.showLabel,
            onChanged: (v) => setState(() => L.showLabel = v),
          ),
        ]),

        // Estilo del rastro
        if (L.showTrail) ...[
          Wrap(spacing: 6, children: [
            for (final s in const [
              ['triangle', 'Triángulos'],
              ['icon', 'Iconos'],
              ['dots', 'Puntos'],
              ['line', 'Línea'],
            ])
              ChoiceChip(
                label: Text(s[1]),
                selected: L.trailStyle == s[0],
                onSelected: (_) => setState(() => L.trailStyle = s[0]),
              ),
          ]),
          // Selector de icono
          if (L.trailStyle == 'icon') ...[
            const SizedBox(height: 8),
            Wrap(spacing: 4, children: [
              for (final ic in kTrailIcons)
                IconButton(
                  isSelected: L.icon.codePoint == ic.codePoint,
                  onPressed: () => setState(() => L.icon = ic),
                  icon: Icon(ic,
                      color: L.icon.codePoint == ic.codePoint ? L.color : null),
                ),
            ]),
          ],
        ],
      ],
    );
  }
}


// ============================================================================
//  Modelo de capa (con estado de estilo editable en el cliente)
// ============================================================================
const List<IconData> kTrailIcons = [
  Icons.star,
  Icons.circle,
  Icons.smart_toy,
  Icons.sports_soccer,
  Icons.arrow_upward,
  Icons.favorite,
];

// ============================================================================
//  Pintor del lienzo: dibuja el frame + las máscaras por capa + los vectores,
//  TODO en una sola pasada (sincronizado, sin desfase).
// ============================================================================
class CanvasPainter extends CustomPainter {
  final ui.Image? baseImg;        // frame original ya decodificado
  final List<LayerView> layers;
  final List<FrameObj> present;   // objetos detectados en el frame actual
  final double vw, vh;            // dimensiones originales del video
  final int currentFrame;
  CanvasPainter({
    required this.baseImg,
    required this.layers,
    required this.present,
    required this.vw,
    required this.vh,
    required this.currentFrame,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / vw, sy = size.height / vh;
    final byId = {for (final fo in present) fo.id: fo};
    final layerById = {for (final L in layers) L.id: L};
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);

    // 1) El frame base
    if (baseImg != null) {
      final src = Rect.fromLTWH(
          0, 0, baseImg!.width.toDouble(), baseImg!.height.toDouble());
      canvas.drawImageRect(baseImg!, src, dst, Paint());
    }

    // 2) Las máscaras por capa, tintadas con el color de la capa (si la capa
    //    está visible y NO en modo caja). Se dibujan en el MISMO lienzo.
    for (final fo in present) {
      final L = layerById[fo.id];
      if (L == null || !L.maskVisible || L.boxMode) continue;
      final img = fo.maskImg;
      if (img == null) continue;
      final src =
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
      final p = Paint()
        ..colorFilter =
            ColorFilter.mode(L.color.withOpacity(0.5), BlendMode.srcIn);
      canvas.drawImageRect(img, src, dst, p);
    }

    // 3) Encima: cajas + rastros + etiquetas (vectoriales)
    for (final L in layers) {
      final fo = byId[L.id];      // puede ser null: no detectado en este frame

      // Caja: solo si está presente este frame
      if (fo != null && L.maskVisible && L.boxMode) {
        final r = Rect.fromLTRB(
            fo.bbox[0] * sx, fo.bbox[1] * sy, fo.bbox[2] * sx, fo.bbox[3] * sy);
        canvas.drawRect(
          r,
          Paint()
            ..color = L.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }

      // Rastro: colgado (crece hasta el frame actual, esté o no presente)
      if (L.showTrail && L.trail.isNotEmpty) _paintTrail(canvas, L, sx, sy);

      // Etiqueta: colgada en la última posición conocida hasta el frame actual
      if (L.showLabel) {
        Offset? pos;
        if (fo != null) {
          pos = Offset((fo.bbox[0] + fo.bbox[2]) / 2 * sx,
              (fo.bbox[1] + fo.bbox[3]) / 2 * sy);
        } else {
          for (final t in L.trail) {
            if (t.$1 <= currentFrame) {
              pos = Offset(t.$2.dx * sx, t.$2.dy * sy);
            }
          }
        }
        if (pos != null) _drawLabel(canvas, L.name, pos, L.color);
      }
    }
  }

  void _paintTrail(Canvas canvas, LayerView L, double sx, double sy) {
    final pts = <Offset>[];
    for (final t in L.trail) {
      if (t.$1 <= currentFrame) pts.add(Offset(t.$2.dx * sx, t.$2.dy * sy));
    }
    if (pts.isEmpty) return;

    if (L.trailStyle == 'line') {
      final paint = Paint()
        ..color = L.color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    } else if (L.trailStyle == 'dots') {
      final fill = Paint()..color = L.color..style = PaintingStyle.fill;
      for (final p in pts) {
        canvas.drawCircle(p, 4, fill);
      }
    } else {
      // 'icon' o 'triangle' -> cadena espaciada y orientada
      final drawn = <Offset>[];
      for (final p in pts) {
        if (drawn.isEmpty || (p - drawn.last).distance >= 28) drawn.add(p);
      }
      if (drawn.last != pts.last) drawn.add(pts.last);
      for (int i = 0; i < drawn.length; i++) {
        Offset dir;
        if (i < drawn.length - 1) {
          dir = drawn[i + 1] - drawn[i];
        } else if (i > 0) {
          dir = drawn[i] - drawn[i - 1];
        } else {
          dir = const Offset(0, -1);
        }
        if (dir.distance < 0.01) dir = const Offset(0, -1);
        final angle = atan2(dir.dy, dir.dx) + pi / 2;
        if (L.trailStyle == 'triangle') {
          _drawTriangle(canvas, drawn[i], angle, L.color, 12);
        } else {
          _drawIcon(canvas, L.icon, drawn[i], angle, L.color, 24);
        }
      }
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
            color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    const pad = 5.0;
    final rect = Rect.fromLTWH(
        at.dx + 10, at.dy - tp.height / 2 - pad, tp.width + pad * 2, tp.height + pad);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = color.withOpacity(0.85),
    );
    tp.paint(canvas, Offset(rect.left + pad, rect.top + pad / 2));
  }

  void _drawTriangle(Canvas canvas, Offset at, double angle, Color color, double r) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    final path = Path()
      ..moveTo(0, -r)              // punta hacia arriba (apunta al objeto)
      ..lineTo(r * 0.8, r * 0.7)
      ..lineTo(-r * 0.8, r * 0.7)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
    canvas.restore();
  }

  void _drawIcon(Canvas canvas, IconData icon, Offset at, double angle,
      Color color, double px) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        fontSize: px,
        color: color,
      ),
    );
    tp.layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CanvasPainter old) => true;
}