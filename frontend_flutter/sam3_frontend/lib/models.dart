// ============================================================================
//  models.dart — Modelos de datos compartidos
//  FrameObj  : un objeto detectado en un frame (caja + máscara)
//  LayerView : una capa/objeto rastreado, con su estilo editable (vista
//              principal y vista táctica 2D)
// ============================================================================
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class FrameObj {
  final int id;
  final List<double> bbox;   // x1,y1,x2,y2 en píxeles del video
  final String mask;         // png base64 (blanco donde está el objeto)
  ui.Image? maskImg;         // la máscara YA decodificada (se llena al recibir)
  FrameObj(this.id, this.bbox, this.mask);
}

class LayerView {
  final int id;
  final Color color;
  final List<(int, Offset)> trail;   // (frame, posición en píxeles del video)
  final String label;
  String name;
  bool showTrail;
  bool showLabel;
  bool maskVisible;
  bool boxMode;
  String trailStyle;          // 'line' | 'dots' | 'icon' | 'triangle'
  IconData icon;

  // --- Representación en la cancha 2D (vista táctica) ---
  bool isBall;                // detectado por la etiqueta (pelota/ball)
  String shape2d;            // 'square' | 'triangle' | 'circle'
  Color color2d;             // rojo/azul (robots) · naranja/negro (pelota)
  bool show2dTrail;          // rastro de flechas en la cancha 2D
  bool show2dLabel;          // etiqueta en la cancha 2D

  LayerView({
    required this.id,
    required this.color,
    required this.trail,
    required this.label,
  })  : name = '$label #$id',
        showTrail = false,
        showLabel = false,
        maskVisible = true,
        boxMode = false,
        trailStyle = 'icon',
        icon = Icons.arrow_upward,
        isBall = RegExp(r'pelota|ball|bola', caseSensitive: false)
            .hasMatch(label),
        shape2d = RegExp(r'pelota|ball|bola', caseSensitive: false)
                .hasMatch(label)
            ? 'circle'
            : 'square',
        color2d = RegExp(r'pelota|ball|bola', caseSensitive: false)
                .hasMatch(label)
            ? const Color(0xFFFF8A00)   // naranja (pelota)
            : const Color(0xFFE53935),  // rojo (robot por defecto)
        show2dTrail = false,
        show2dLabel = false;
}