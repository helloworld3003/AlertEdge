import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// NightVisionProcessor — Lightweight image enhancement pipeline for nighttime
/// drowsiness detection.
///
/// This class implements a targeted ROI-based processing strategy:
///   1. Crop to the upper half of the detected face bounding box (eye region only)
///   2. Apply CLAHE to normalize contrast without overexposing highlights
///   3. Apply Gamma Correction to lift mid-tones and shadows
///   4. Recombine the enhanced ROI back into the full frame
///
/// All operations use the pure-Dart `image` package (no native FFI required),
/// keeping the pipeline cross-platform and dependency-light. Processing time
/// target: <15ms per frame on modern Android SoCs at QVGA (320x240).
class NightVisionProcessor {
  /// Gamma correction exponent. Values >1.0 brighten mid-tones/shadows.
  /// Recommended range for nighttime ambient light: 1.5 – 2.0
  final double gamma;

  /// CLAHE clip limit — controls contrast amplification ceiling.
  /// Higher values allow more contrast but risk amplifying noise.
  /// 2.0–4.0 is standard; we use 3.0 as a balanced default.
  final double clipLimit;

  /// Number of tiles for CLAHE grid (both X and Y dimensions).
  /// 8x8 is the standard OpenCV default. Smaller values = coarser equalization.
  final int tileGridSize;

  /// Pre-computed gamma Look-Up Table for O(1) pixel mapping.
  late final Uint8List _gammaLUT;

  NightVisionProcessor({
    this.gamma = 1.4,       // Was 1.8 — lower = less noise amplification
    this.clipLimit = 1.8,   // Was 3.0 — lower = softer contrast, less tile artefacts
    this.tileGridSize = 4,  // Was 8 — fewer larger tiles = smoother histograms
  }) {
    _buildGammaLUT();
  }

  /// Pre-compute the gamma correction LUT once at construction time.
  /// Each pixel value [0-255] is mapped to its gamma-corrected output.
  void _buildGammaLUT() {
    _gammaLUT = Uint8List(256);
    final invGamma = 1.0 / gamma;
    for (int i = 0; i < 256; i++) {
      _gammaLUT[i] = (pow(i / 255.0, invGamma) * 255.0).round().clamp(0, 255);
    }
  }

  /// Main entry point: Enhances the eye region of a JPEG frame.
  ///
  /// [jpegBytes]   — Raw JPEG frame from the ESP32-CAM MJPEG stream.
  /// [faceRect]    — Bounding box of the detected face (from Google ML Kit).
  ///
  /// Returns the full-frame JPEG with the eye-region ROI enhanced,
  /// or `null` if decoding fails.
  Uint8List? enhanceFrame(Uint8List jpegBytes, Rect faceRect) {
    // --- Decode JPEG to pixel buffer ---
    final image = img.decodeJpg(jpegBytes);
    if (image == null) return null;

    // --- Step A & B: Define Eye-Region ROI ---
    // The eye region is the upper half of the face bounding box.
    // Clamp to image boundaries to avoid out-of-range access.
    final int roiX = faceRect.left.round().clamp(0, image.width - 1);
    final int roiY = faceRect.top.round().clamp(0, image.height - 1);
    final int roiW = faceRect.width.round().clamp(1, image.width - roiX);
    // Upper half only — eyes live in the top 50% of the face bounding box
    final int roiH = (faceRect.height / 2.0).round().clamp(1, image.height - roiY);

    // --- Extract the ROI sub-image ---
    final roi = img.copyCrop(
      image,
      x: roiX,
      y: roiY,
      width: roiW,
      height: roiH,
    );

    // --- Step C: CLAHE → Gamma ---
    // No pre-blur needed: ESP32 firmware runs denoise=1, so frames arrive
    // pre-smoothed at the sensor level before JPEG encoding.
    _applyCLAHE(roi);

    // --- Step D: Gamma Correction on the ROI ---
    _applyGammaCorrection(roi);

    // --- Step E: Paste enhanced ROI back into the full frame ---
    img.compositeImage(image, roi, dstX: roiX, dstY: roiY);

    // --- Re-encode to JPEG for downstream consumers ---
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  /// Enhances and returns ONLY the eye-region ROI as a decoded Image.
  /// This is the fast path used by [DrowsinessDetector] — we skip the
  /// full-frame re-encode since EAR calculation only needs landmark coords.
  ///
  /// Returns the enhanced ROI image, or null if decoding fails.
  img.Image? enhanceEyeRegion(Uint8List jpegBytes, Rect faceRect) {
    final image = img.decodeJpg(jpegBytes);
    if (image == null) return null;

    final int roiX = faceRect.left.round().clamp(0, image.width - 1);
    final int roiY = faceRect.top.round().clamp(0, image.height - 1);
    final int roiW = faceRect.width.round().clamp(1, image.width - roiX);
    final int roiH = (faceRect.height / 2.0).round().clamp(1, image.height - roiY);

    final roi = img.copyCrop(image, x: roiX, y: roiY, width: roiW, height: roiH);

    _applyCLAHE(roi);
    _applyGammaCorrection(roi);

    img.compositeImage(image, roi, dstX: roiX, dstY: roiY);
    return image;
  }

  // =========================================================================
  //  CLAHE — Contrast Limited Adaptive Histogram Equalization
  // =========================================================================
  //
  //  This is a pure-Dart implementation of the CLAHE algorithm. It divides
  //  the image into a grid of tiles, computes a clipped histogram for each
  //  tile, and uses bilinear interpolation between neighboring tile CDFs
  //  to produce a smooth, artifact-free result.
  //
  //  Why not use OpenCV via FFI? Because:
  //    1) The `image` package is already a dependency (zero added weight)
  //    2) Our ROI is tiny (160x60 pixels typical) — pure Dart is fast enough
  //    3) Avoids platform-specific native build complexity
  // =========================================================================

  void _applyCLAHE(img.Image roi) {
    final int w = roi.width;
    final int h = roi.height;

    // Extract luminance channel (grayscale intensity)
    final Uint8List luminance = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final pixel = roi.getPixel(x, y);
        // For grayscale JPEG from ESP32, R≈G≈B, so just use luminance
        luminance[y * w + x] = pixel.luminance.round().clamp(0, 255);
      }
    }

    // Compute tile dimensions
    final int tilesX = tileGridSize.clamp(1, w);
    final int tilesY = tileGridSize.clamp(1, h);
    final double tileW = w / tilesX;
    final double tileH = h / tilesY;
    final int tilePixels = (tileW * tileH).round().clamp(1, w * h);

    // Compute the clip limit in absolute histogram count terms
    final int clipCount = (clipLimit * tilePixels / 256).round().clamp(1, tilePixels);

    // Build CDF for each tile
    // cdfs[ty][tx] is a Uint8List(256) mapping input intensity → equalized output
    final List<List<Uint8List>> cdfs = List.generate(
      tilesY,
      (ty) => List.generate(tilesX, (tx) {
        // Tile boundaries
        final int x0 = (tx * tileW).round().clamp(0, w - 1);
        final int y0 = (ty * tileH).round().clamp(0, h - 1);
        final int x1 = ((tx + 1) * tileW).round().clamp(x0 + 1, w);
        final int y1 = ((ty + 1) * tileH).round().clamp(y0 + 1, h);

        // Build histogram
        final List<int> hist = List<int>.filled(256, 0);
        int count = 0;
        for (int y = y0; y < y1; y++) {
          for (int x = x0; x < x1; x++) {
            hist[luminance[y * w + x]]++;
            count++;
          }
        }
        if (count == 0) count = 1;

        // Clip histogram and redistribute excess
        int excess = 0;
        for (int i = 0; i < 256; i++) {
          if (hist[i] > clipCount) {
            excess += hist[i] - clipCount;
            hist[i] = clipCount;
          }
        }
        final int perBin = excess ~/ 256;
        final int remainder = excess - perBin * 256;
        for (int i = 0; i < 256; i++) {
          hist[i] += perBin;
        }
        // Distribute remainder across first bins
        for (int i = 0; i < remainder; i++) {
          hist[i]++;
        }

        // Build CDF and normalize to [0, 255]
        final Uint8List cdf = Uint8List(256);
        int cumulative = 0;
        for (int i = 0; i < 256; i++) {
          cumulative += hist[i];
          cdf[i] = ((cumulative * 255) ~/ count).clamp(0, 255);
        }

        return cdf;
      }),
    );

    // Apply bilinear interpolation between tile CDFs for smooth output
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final double fx = (x / tileW) - 0.5;
        final double fy = (y / tileH) - 0.5;

        int tx0 = fx.floor().clamp(0, tilesX - 1);
        int ty0 = fy.floor().clamp(0, tilesY - 1);
        int tx1 = (tx0 + 1).clamp(0, tilesX - 1);
        int ty1 = (ty0 + 1).clamp(0, tilesY - 1);

        final double ax = (fx - tx0).clamp(0.0, 1.0);
        final double ay = (fy - ty0).clamp(0.0, 1.0);

        final int val = luminance[y * w + x];

        // Bilinear interpolation of the four surrounding tile CDFs
        final double topLeft = cdfs[ty0][tx0][val].toDouble();
        final double topRight = cdfs[ty0][tx1][val].toDouble();
        final double bottomLeft = cdfs[ty1][tx0][val].toDouble();
        final double bottomRight = cdfs[ty1][tx1][val].toDouble();

        final double top = topLeft * (1 - ax) + topRight * ax;
        final double bottom = bottomLeft * (1 - ax) + bottomRight * ax;
        final int result = (top * (1 - ay) + bottom * ay).round().clamp(0, 255);

        // Write back — set all channels equally (grayscale)
        roi.setPixelRgba(x, y, result, result, result, 255);
      }
    }
  }

  // =========================================================================
  //  Gamma Correction — LUT-based O(1) per-pixel
  // =========================================================================

  void _applyGammaCorrection(img.Image roi) {
    final int w = roi.width;
    final int h = roi.height;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final pixel = roi.getPixel(x, y);
        final int r = _gammaLUT[pixel.r.round().clamp(0, 255)];
        final int g = _gammaLUT[pixel.g.round().clamp(0, 255)];
        final int b = _gammaLUT[pixel.b.round().clamp(0, 255)];
        roi.setPixelRgba(x, y, r, g, b, 255);
      }
    }
  }
}

/// Simple rectangle class to avoid Flutter framework dependency in this service.
/// Maps directly from ML Kit's BoundingBox/Rect values.
class Rect {
  final double left;
  final double top;
  final double width;
  final double height;

  const Rect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double get right => left + width;
  double get bottom => top + height;
}
