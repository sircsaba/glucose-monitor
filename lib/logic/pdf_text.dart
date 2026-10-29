import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Reads the text of a PDF made from a document (Word, a web page saved as
/// PDF, a recipe site's "print" button...). Pure Dart, so it also works in the
/// browser. A scanned PDF has pictures instead of text: this then returns
/// (almost) nothing, and the phone reads the page pictures instead.
List<String> pdfPageTexts(Uint8List bytes) {
  final doc = _PdfDoc(bytes);
  doc.load();
  if (doc.encrypted) return [];
  final out = <String>[];
  for (final page in doc.pages()) {
    try {
      out.add(doc.pageText(page));
    } catch (_) {
      out.add('');
    }
  }
  return out;
}

/// The whole text, pages one after another.
String pdfText(Uint8List bytes) => pdfPageTexts(bytes).where((t) => t.trim().isNotEmpty).join('\n');

/// True when the text read is too little to be the recipe (a scanned PDF).
bool pdfLooksScanned(String text) => RegExp(r'[A-Za-zÀ-ÿ]').allMatches(text).length < 40;

// ------------------------------------------------------------------ objects

class _Ref {
  final int n;
  const _Ref(this.n);
}

class _Name {
  final String v;
  const _Name(this.v);
  @override
  bool operator ==(Object o) => o is _Name && o.v == v;
  @override
  int get hashCode => v.hashCode;
}

class _Op {
  final String v;
  const _Op(this.v);
}

class _Stream {
  final Map<String, Object?> dict;
  final Uint8List raw;
  _Stream(this.dict, this.raw);
}

/// Tokens and objects of PDF syntax.
class _Lexer {
  final Uint8List b;
  int i;
  _Lexer(this.b, [this.i = 0]);

  bool get end => i >= b.length;

  static bool _ws(int c) => c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0;
  static bool _delim(int c) => c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37;

  void skip() {
    while (i < b.length) {
      final c = b[i];
      if (_ws(c)) {
        i++;
      } else if (c == 37) {
        while (i < b.length && b[i] != 10 && b[i] != 13) {
          i++;
        }
      } else {
        break;
      }
    }
  }

  String _word() {
    final s = i;
    while (i < b.length && !_ws(b[i]) && !_delim(b[i])) {
      i++;
    }
    return latin1.decode(b.sublist(s, i));
  }

  /// One object; [ops] true reads operators (content streams).
  Object? read({bool ops = false}) {
    skip();
    if (end) return null;
    final c = b[i];
    if (c == 47) {
      i++;
      var w = _word();
      w = w.replaceAllMapped(RegExp(r'#([0-9a-fA-F]{2})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
      return _Name(w);
    }
    if (c == 40) return _literal();
    if (c == 60) {
      if (i + 1 < b.length && b[i + 1] == 60) {
        i += 2;
        final d = <String, Object?>{};
        while (true) {
          skip();
          if (end) break;
          if (b[i] == 62 && i + 1 < b.length && b[i + 1] == 62) {
            i += 2;
            break;
          }
          final k = read(ops: ops);
          if (k is! _Name) {
            if (k == null) break;
            continue;
          }
          d[k.v] = read(ops: ops);
        }
        return d;
      }
      return _hex();
    }
    if (c == 91) {
      i++;
      final a = <Object?>[];
      while (true) {
        skip();
        if (end) break;
        if (b[i] == 93) {
          i++;
          break;
        }
        a.add(read(ops: ops));
      }
      return a;
    }
    if (c == 93 || c == 62 || c == 41 || c == 123 || c == 125) {
      i++;
      return const _Op('');
    }
    final w = _word();
    if (w.isEmpty) {
      i++;
      return const _Op('');
    }
    final n = num.tryParse(w);
    if (n != null) {
      if (!ops && n is int) {
        // "12 0 R" is a reference.
        final save = i;
        skip();
        final g = _word();
        if (int.tryParse(g) != null) {
          skip();
          if (i < b.length && b[i] == 82 && (i + 1 >= b.length || _ws(b[i + 1]) || _delim(b[i + 1]))) {
            i++;
            return _Ref(n);
          }
        }
        i = save;
      }
      return n;
    }
    if (w == 'true') return true;
    if (w == 'false') return false;
    if (w == 'null') return null;
    return _Op(w);
  }

  Uint8List _literal() {
    i++;
    final out = BytesBuilder();
    var depth = 1;
    while (i < b.length) {
      var c = b[i++];
      if (c == 92 && i < b.length) {
        c = b[i++];
        switch (c) {
          case 110:
            out.addByte(10);
          case 114:
            out.addByte(13);
          case 116:
            out.addByte(9);
          case 98:
            out.addByte(8);
          case 102:
            out.addByte(12);
          case 10:
            break;
          case 13:
            if (i < b.length && b[i] == 10) i++;
          default:
            if (c >= 48 && c <= 55) {
              var v = c - 48;
              for (var k = 0; k < 2 && i < b.length && b[i] >= 48 && b[i] <= 55; k++) {
                v = v * 8 + b[i++] - 48;
              }
              out.addByte(v & 255);
            } else {
              out.addByte(c);
            }
        }
        continue;
      }
      if (c == 40) depth++;
      if (c == 41) {
        depth--;
        if (depth == 0) break;
      }
      out.addByte(c);
    }
    return out.toBytes();
  }

  Uint8List _hex() {
    i++;
    final h = StringBuffer();
    while (i < b.length && b[i] != 62) {
      final c = b[i++];
      if ((c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)) h.writeCharCode(c);
    }
    i++;
    var s = h.toString();
    if (s.length.isOdd) s += '0';
    return Uint8List.fromList([for (var k = 0; k < s.length; k += 2) int.parse(s.substring(k, k + 2), radix: 16)]);
  }
}

class _PdfDoc {
  final Uint8List b;
  final Map<int, Object?> objs = {};
  bool encrypted = false;
  _PdfDoc(this.b);

  int _find(List<int> pat, int from) {
    outer:
    for (var k = from; k <= b.length - pat.length; k++) {
      for (var j = 0; j < pat.length; j++) {
        if (b[k + j] != pat[j]) continue outer;
      }
      return k;
    }
    return -1;
  }

  void load() {
    final s = latin1.decode(b, allowInvalid: true);
    for (final m in RegExp(r'(\d+)\s+(\d+)\s+obj\b').allMatches(s)) {
      final n = int.parse(m.group(1)!);
      final lx = _Lexer(b, m.end);
      Object? o;
      try {
        o = lx.read();
      } catch (_) {
        continue;
      }
      if (o is Map<String, Object?>) {
        lx.skip();
        if (lx.i + 6 <= b.length && latin1.decode(b.sublist(lx.i, lx.i + 6)) == 'stream') {
          var start = lx.i + 6;
          if (start < b.length && b[start] == 13) start++;
          if (start < b.length && b[start] == 10) start++;
          final len = o['Length'];
          var stop = len is int && start + len <= b.length ? start + len : -1;
          if (stop < 0 || _find(const [101, 110, 100, 115, 116, 114, 101, 97, 109], stop) - stop > 20) {
            stop = _find(const [101, 110, 100, 115, 116, 114, 101, 97, 109], start); // endstream
            if (stop < 0) stop = b.length;
          }
          o = _Stream(o, Uint8List.sublistView(b, start, stop));
        }
      }
      objs[n] = o; // later copies (updates) replace earlier ones
    }
    // Objects packed in object streams (PDF 1.5 and later).
    for (final o in objs.values.toList()) {
      if (o is _Stream && _name(o.dict['Type']) == 'ObjStm') {
        final data = decode(o);
        if (data == null) continue;
        final count = o.dict['N'];
        final first = o.dict['First'];
        if (count is! int || first is! int) continue;
        final head = _Lexer(data);
        final pairs = <(int, int)>[];
        for (var k = 0; k < count; k++) {
          final on = head.read(ops: true), off = head.read(ops: true);
          if (on is int && off is int) pairs.add((on, off));
        }
        for (final (on, off) in pairs) {
          if (objs.containsKey(on) && objs[on] != null) continue;
          try {
            objs[on] = _Lexer(data, first + off).read();
          } catch (_) {}
        }
      }
    }
    final trailer = RegExp(r'trailer\s*<<[\s\S]*?/Encrypt').hasMatch(s) ||
        objs.values.any((o) => o is _Stream && _name(o.dict['Type']) == 'XRef' && o.dict.containsKey('Encrypt'));
    encrypted = trailer;
  }

  Object? get(Object? o) {
    var k = 0;
    while (o is _Ref && k++ < 20) {
      o = objs[o.n];
    }
    return o;
  }

  static String? _name(Object? o) => o is _Name ? o.v : null;

  Uint8List? decode(_Stream s) {
    var f = get(s.dict['Filter']);
    final filters = f is List ? [for (final x in f) _name(get(x))] : [_name(f)];
    Uint8List data = s.raw;
    for (final name in filters) {
      if (name == null) continue;
      if (name == 'FlateDecode' || name == 'Fl') {
        try {
          data = Uint8List.fromList(const ZLibDecoder().decodeBytes(data));
        } catch (_) {
          return null;
        }
      } else {
        return null; // images and other codecs carry no text
      }
    }
    return data;
  }

  /// Pages in reading order.
  List<Map<String, Object?>> pages() {
    final out = <Map<String, Object?>>[];
    void walk(Object? node, int depth) {
      final n = get(node);
      if (n is! Map<String, Object?> || depth > 30) return;
      final t = _name(n['Type']);
      if (t == 'Page' || (t == null && n.containsKey('Contents'))) {
        out.add(n);
      } else if (n['Kids'] is List || get(n['Kids']) is List) {
        for (final k in get(n['Kids']) as List) {
          walk(k, depth + 1);
        }
      }
    }

    final cat = objs.values.whereType<Map<String, Object?>>().where((d) => _name(d['Type']) == 'Catalog').firstOrNull;
    if (cat != null) walk(cat['Pages'], 0);
    if (out.isEmpty) {
      final keys = objs.keys.toList()..sort();
      for (final k in keys) {
        final o = objs[k];
        if (o is Map<String, Object?> && _name(o['Type']) == 'Page') out.add(o);
      }
    }
    return out;
  }

  Object? _inherited(Map<String, Object?> page, String key) {
    Object? n = page;
    for (var k = 0; k < 30 && n is Map<String, Object?>; k++) {
      if (n.containsKey(key)) return get(n[key]);
      n = get(n['Parent']);
    }
    return null;
  }

  final Map<Object, _Font> _fonts = {};

  _Font _font(Object? ref) {
    final key = ref is _Ref ? ref.n : identityHashCode(ref);
    return _fonts[key] ??= _Font.from(this, get(ref));
  }

  String pageText(Map<String, Object?> page) {
    final res = _inherited(page, 'Resources');
    final fontDict = res is Map<String, Object?> ? get(res['Font']) : null;
    final contents = get(page['Contents']);
    final parts = <Uint8List>[];
    for (final c in contents is List ? contents : [contents]) {
      final s = get(c);
      if (s is _Stream) {
        final d = decode(s);
        if (d != null) parts.add(d);
      }
    }
    final bb = BytesBuilder();
    for (final p in parts) {
      bb.add(p);
      bb.addByte(10);
    }
    return _run(bb.toBytes(), fontDict is Map<String, Object?> ? fontDict : const {}, res is Map<String, Object?> ? res : const {}, 0);
  }

  /// Plays the content stream and writes its text, a new line when the text moves down.
  String _run(Uint8List content, Map<String, Object?> fonts, Map<String, Object?> res, int depth) {
    final out = StringBuffer();
    final lx = _Lexer(content);
    final args = <Object?>[];
    _Font? font;
    double fontSize = 10;
    // Where the text is (line matrix), and where the last text was shown.
    double lx0 = 0, ly0 = 0;
    double? lastX, lastY;
    var charsSince = 0;
    void newline() {
      if (out.isNotEmpty && !out.toString().endsWith('\n')) out.write('\n');
    }

    void space() {
      final t = out.toString();
      if (t.isNotEmpty && !t.endsWith(' ') && !t.endsWith('\n')) out.write(' ');
    }

    // Text moved to (x, y): a new line when it goes up or down, a space when
    // it jumps right further than the text shown since.
    void moved(double x, double y) {
      if (lastY != null && (y - lastY!).abs() > fontSize * 0.4 + 0.5) {
        newline();
      } else if (lastX != null) {
        final gap = x - (lastX! + charsSince * fontSize * 0.45);
        if (gap > fontSize * 0.15 || x < lastX!) space();
      }
      lastX = x;
      lastY = y;
      charsSince = 0;
    }

    void show(Uint8List s) {
      final t = (font ?? _Font.plain).text(s);
      out.write(t);
      charsSince += t.length;
    }

    while (!lx.end) {
      final t = lx.read(ops: true);
      if (t == null && lx.end) break;
      if (t is! _Op) {
        args.add(t);
        continue;
      }
      switch (t.v) {
        case 'BT':
          lx0 = 0;
          ly0 = 0;
        case 'Tf':
          if (args.length >= 2 && args[0] is _Name) {
            font = _font(fonts[(args[0] as _Name).v]);
            final sz = args[1];
            if (sz is num && sz != 0) fontSize = sz.toDouble().abs();
          }
        case 'Td' || 'TD':
          if (args.length >= 2 && args[0] is num && args[1] is num) {
            lx0 += (args[0] as num).toDouble();
            ly0 += (args[1] as num).toDouble();
            moved(lx0, ly0);
          }
        case 'Tm':
          if (args.length >= 6 && args[4] is num && args[5] is num) {
            final a0 = args[0], d0 = args[3];
            // A scaled matrix with "1 Tf": the size is in the matrix.
            if (a0 is num && d0 is num && fontSize <= 1.01) fontSize = d0.toDouble().abs() > 0 ? d0.toDouble().abs() * fontSize : fontSize;
            lx0 = (args[4] as num).toDouble();
            ly0 = (args[5] as num).toDouble();
            moved(lx0, ly0);
          }
        case 'T*':
          newline();
          lastY = null;
          lastX = null;
        case 'Tj':
          if (args.isNotEmpty && args.last is Uint8List) show(args.last as Uint8List);
        case "'" || '"':
          newline();
          lastY = null;
          lastX = null;
          if (args.isNotEmpty && args.last is Uint8List) show(args.last as Uint8List);
        case 'TJ':
          final a = args.isNotEmpty ? args.last : null;
          if (a is List) {
            for (final x in a) {
              if (x is Uint8List) {
                show(x);
              } else if (x is num && x < -180) {
                space();
              }
            }
          }
        case 'ET':
          break;
        case 'Do':
          // Text inside a form (some exporters put each page in one).
          if (depth < 3 && args.isNotEmpty && args.last is _Name) {
            final xo = get(res['XObject']);
            final f = xo is Map<String, Object?> ? get(xo[(args.last as _Name).v]) : null;
            if (f is _Stream && _name(f.dict['Subtype']) == 'Form') {
              final d = decode(f);
              final r2 = get(f.dict['Resources']);
              final rr = r2 is Map<String, Object?> ? r2 : res;
              final f2 = get(rr['Font']);
              if (d != null) {
                newline();
                out.write(_run(d, f2 is Map<String, Object?> ? f2 : fonts, rr, depth + 1));
                newline();
              }
            }
          }
      }
      args.clear();
    }
    return out
        .toString()
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }
}

/// How a font's codes turn into letters.
class _Font {
  final Map<int, String> map;
  final int bytes; // 1 or 2 bytes a code
  _Font(this.map, this.bytes);

  static final plain = _Font(const {}, 1);

  static _Font from(_PdfDoc d, Object? f) {
    if (f is! Map<String, Object?>) return plain;
    final tu = d.get(f['ToUnicode']);
    final subtype = _PdfDoc._name(f['Subtype']);
    var two = subtype == 'Type0';
    final map = <int, String>{};
    if (tu is _Stream) {
      final data = d.decode(tu);
      if (data != null) {
        final cm = latin1.decode(data, allowInvalid: true);
        final cs = RegExp(r'begincodespacerange\s*<([0-9a-fA-F]+)>').firstMatch(cm);
        if (cs != null) two = cs.group(1)!.length >= 4;
        for (final blk in RegExp(r'beginbfchar([\s\S]*?)endbfchar').allMatches(cm)) {
          for (final m in RegExp(r'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]*)>').allMatches(blk.group(1)!)) {
            map[int.parse(m.group(1)!, radix: 16)] = _utf16(m.group(2)!);
          }
        }
        for (final blk in RegExp(r'beginbfrange([\s\S]*?)endbfrange').allMatches(cm)) {
          for (final m in RegExp(r'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(<[0-9a-fA-F]*>|\[[^\]]*\])').allMatches(blk.group(1)!)) {
            final lo = int.parse(m.group(1)!, radix: 16), hi = int.parse(m.group(2)!, radix: 16);
            final dst = m.group(3)!;
            if (hi - lo > 5000) continue;
            if (dst.startsWith('[')) {
              final items = RegExp(r'<([0-9a-fA-F]*)>').allMatches(dst).map((x) => x.group(1)!).toList();
              for (var k = 0; k <= hi - lo && k < items.length; k++) {
                map[lo + k] = _utf16(items[k]);
              }
            } else {
              final h = dst.substring(1, dst.length - 1);
              if (h.isEmpty) continue;
              final base = h.length > 4 ? h.substring(0, h.length - 4) : '';
              final last = int.parse(h.length > 4 ? h.substring(h.length - 4) : h, radix: 16);
              for (var k = 0; k <= hi - lo; k++) {
                map[lo + k] = _utf16(base) + String.fromCharCode(last + k);
              }
            }
          }
        }
      }
    } else if (!two) {
      // Simple fonts: WinAnsi (like Windows-1252), with /Differences.
      final enc = d.get(f['Encoding']);
      if (enc is Map<String, Object?>) {
        final diff = d.get(enc['Differences']);
        if (diff is List) {
          var code = 0;
          for (final x in diff) {
            final v = d.get(x);
            if (v is int) {
              code = v;
            } else if (v is _Name) {
              final ch = _glyph(v.v);
              if (ch != null) map[code] = ch;
              code++;
            }
          }
        }
      }
    }
    return _Font(map, two ? 2 : 1);
  }

  static String _utf16(String hex) {
    final units = <int>[for (var k = 0; k + 4 <= hex.length; k += 4) int.parse(hex.substring(k, k + 4), radix: 16)];
    if (units.isEmpty && hex.length == 2) return String.fromCharCode(int.parse(hex, radix: 16));
    return String.fromCharCodes(units);
  }

  String text(Uint8List s) {
    final sb = StringBuffer();
    if (bytes == 2) {
      for (var k = 0; k + 1 < s.length; k += 2) {
        final c = s[k] << 8 | s[k + 1];
        final v = map[c];
        if (v != null) sb.write(v);
      }
    } else {
      for (final c in s) {
        sb.write(map[c] ?? _win[c] ?? (c >= 32 ? String.fromCharCode(c) : ''));
      }
    }
    return sb.toString();
  }

  static const _win = {
    0x80: '€', 0x82: '‚', 0x83: 'ƒ', 0x84: '„', 0x85: '…', 0x86: '†', 0x87: '‡', 0x88: 'ˆ', 0x89: '‰', 0x8A: 'Š', 0x8B: '‹',
    0x8C: 'Œ', 0x8E: 'Ž', 0x91: '‘', 0x92: '’', 0x93: '“', 0x94: '”', 0x95: '•', 0x96: '–', 0x97: '—', 0x98: '˜', 0x99: '™',
    0x9A: 'š', 0x9B: '›', 0x9C: 'œ', 0x9E: 'ž', 0x9F: 'Ÿ', 0xA0: ' ', 0xAD: '-',
  };

  static String? _glyph(String n) {
    const g = {
      'space': ' ', 'period': '.', 'comma': ',', 'colon': ':', 'semicolon': ';', 'hyphen': '-', 'endash': '–', 'emdash': '—',
      'quoteright': '’', 'quoteleft': '‘', 'quotesingle': "'", 'quotedbl': '"', 'quotedblleft': '“', 'quotedblright': '”',
      'parenleft': '(', 'parenright': ')', 'slash': '/', 'percent': '%', 'ampersand': '&', 'bullet': '•', 'degree': '°',
      'onehalf': '½', 'onequarter': '¼', 'threequarters': '¾', 'fi': 'fi', 'fl': 'fl', 'ff': 'ff', 'ffi': 'ffi',
      'zero': '0', 'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5', 'six': '6', 'seven': '7', 'eight': '8', 'nine': '9',
      'eacute': 'é', 'egrave': 'è', 'ecircumflex': 'ê', 'edieresis': 'ë', 'agrave': 'à', 'acircumflex': 'â', 'ccedilla': 'ç',
      'ocircumflex': 'ô', 'icircumflex': 'î', 'idieresis': 'ï', 'ucircumflex': 'û', 'ugrave': 'ù', 'Eacute': 'É', 'Egrave': 'È',
      'question': '?', 'exclam': '!', 'plus': '+', 'equal': '=', 'asterisk': '*', 'numbersign': '#', 'at': '@',
    };
    if (g.containsKey(n)) return g[n];
    if (n.length == 1) return n;
    final u = RegExp(r'^uni([0-9A-Fa-f]{4})$').firstMatch(n);
    if (u != null) return String.fromCharCode(int.parse(u.group(1)!, radix: 16));
    return null;
  }
}
