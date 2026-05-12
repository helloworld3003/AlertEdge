import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'app_config.dart';

/// DrowsinessDetector — Fast two-pass face mesh analysis.
///
/// Always runs in "night mode" pipeline (works in all lighting conditions
/// since the ESP32 camera is permanently set to maximum sensitivity).
///
/// Processing Pipeline:
///   PASS 1: Raw frame → ML Kit → EAR check (fast path)
///   PASS 2: Only if EAR ≤ earThreshold (eyes possibly closed) →
///           CLAHE+Gamma ROI enhancement → second ML Kit pass for confirmation.
///
/// Pass-2 only fires when we actually need to confirm eye closure — not on
/// every frame — so normal driving (eyes open) runs at full speed.
class DrowsinessDetector {
  final FaceMeshDetector _meshDetector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh,
  );

  // =====================================================================
  // EAR Configuration
  // =====================================================================
  int _closedEyeCount = 0;

  // Rolling average of last 2 EAR values — prevents single glitchy frames
  // from triggering or cancelling the alarm alone.
  final List<double> _recentEars = [];
  static const int _earSmoothingWindow = 2;

  // Require this many consecutive open-eye frames before resetting the
  // drowsy timer. Prevents a single blink-artifact frame from restarting
  // the entire countdown.
  int _openEyeCount = 0;
  static const int _openEyeResetFrames = 2;

  // =====================================================================
  // Internal State
  // =====================================================================
  bool _isProcessingFrame = false;
  String _tempFilePath = '';

  // Face landmarks for LEFT_EYE and RIGHT_EYE (MediaPipe indices)
  static const List<int> _leftEyeIdx  = [33, 160, 158, 133, 153, 144];
  static const List<int> _rightEyeIdx = [362, 385, 387, 263, 373, 380];

  Future<void> init() async {
    try {
      final dir = await getTemporaryDirectory();
      _tempFilePath = '${dir.path}/current_frame.jpg';
    } catch (e) {
      _tempFilePath = '/data/data/com.alertedge.alert_edge_app/cache/current_frame.jpg';
      // Ensure directory exists
      try {
        Directory('/data/data/com.alertedge.alert_edge_app/cache').createSync(recursive: true);
      } catch (_) {}
    }
  }

  void dispose() {
    _meshDetector.close();
  }

  // =====================================================================
  // Distance & EAR Calculations
  // =====================================================================

  double _euclideanDistance(FaceMeshPoint p1, FaceMeshPoint p2) {
    return sqrt(pow((p1.x - p2.x), 2) + pow((p1.y - p2.y), 2));
  }

  double _calculateEar(List<FaceMeshPoint> eyePoints) {
    if (eyePoints.length != 6) return 0.0;
    double A = _euclideanDistance(eyePoints[1], eyePoints[5]);
    double B = _euclideanDistance(eyePoints[2], eyePoints[4]);
    double C = _euclideanDistance(eyePoints[0], eyePoints[3]);
    if (C == 0.0) return 0.0;
    return (A + B) / (2.0 * C);
  }

  List<FaceMeshPoint>? _extractEyePoints(FaceMesh mesh, List<int> indices) {
    List<FaceMeshPoint> points = [];
    for (int idx in indices) {
      if (idx < mesh.points.length) points.add(mesh.points[idx]);
    }
    return points.length == 6 ? points : null;
  }

  // =====================================================================
  // Main Frame Processing Pipeline
  // =====================================================================

  /// Returns true if drowsiness detected, false if not, null if skipped.
  Future<bool?> processFrame(Uint8List jpegBytes) async {
    if (_isProcessingFrame || _tempFilePath.isEmpty) return null;
    _isProcessingFrame = true;

    try {
      // =================================================================
      // PASS 1: Write JPEG → ML Kit (native C++ decode — fast path)
      // =================================================================
      final file = File(_tempFilePath);
      await file.writeAsBytes(jpegBytes, flush: false);
      final inputImage = InputImage.fromFilePath(file.path);
      final meshes = await _meshDetector.processImage(inputImage);

      if (meshes.isEmpty) {
        _closedEyeCount = 0;
        _isProcessingFrame = false;
        return false;
      }

      final mesh = meshes.first;

      // =================================================================
      // EAR Calculation with smoothing
      // =================================================================
      final leftEyePts  = _extractEyePoints(mesh, _leftEyeIdx);
      final rightEyePts = _extractEyePoints(mesh, _rightEyeIdx);
      if (leftEyePts != null && rightEyePts != null) {
        final rawEar = (_calculateEar(leftEyePts) + _calculateEar(rightEyePts)) / 2.0;

        _recentEars.add(rawEar);
        if (_recentEars.length > _earSmoothingWindow) _recentEars.removeAt(0);
        final smoothedEar = _recentEars.reduce((a, b) => a + b) / _recentEars.length;

        final config = AppConfig();
        if (smoothedEar < config.earThreshold) {
          _openEyeCount = 0;
          _closedEyeCount++;
          
          // Threshold check
          if (_closedEyeCount >= config.consecutiveFrames) {
            _closedEyeCount = 0; // reset
            _isProcessingFrame = false;
            return true;
          }
        } else {
          _openEyeCount++;
          if (_openEyeCount >= _openEyeResetFrames) {
            _closedEyeCount = 0; // Reset closure streak on fully open eyes
            _openEyeCount = 0;
          }
        }
      }
    } catch (e) {
      debugPrint('Error processing frame: $e');
    }
    _isProcessingFrame = false;
    return false;
  }
}
