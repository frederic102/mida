/// A small, strict XML reader for the Atom feed: elements with resolved
/// namespaces, attributes, text, CDATA, comments and the five predefined
/// entities plus numeric references. No DTD (a DOCTYPE is refused, so no
/// entity tricks), no external anything. Anything malformed throws
/// [FormatException]; the caller turns that into `PARSE_ERROR`.
class XmlElement {
  final String namespace;
  final String name;
  final List<XmlElement> children = [];
  final StringBuffer _text = StringBuffer();

  XmlElement(this.namespace, this.name);

  /// Concatenated character data directly inside this element, trimmed.
  String get text => _text.toString().trim();

  Iterable<XmlElement> childrenNamed(String ns, String local) => children.where((c) => c.namespace == ns && c.name == local);

  /// Every descendant (not including this element) named [local] in [ns].
  int countDescendants(String ns, String local) {
    var n = 0;
    for (final c in children) {
      if (c.namespace == ns && c.name == local) n++;
      n += c.countDescendants(ns, local);
    }
    return n;
  }
}

class XmlReader {
  final String _s;
  var _i = 0;

  XmlReader._(this._s);

  static const _maxDepth = 40;
  static const _xmlNs = 'http://www.w3.org/XML/1998/namespace';
  static final _nameChars = RegExp(r'^[A-Za-z_][A-Za-z0-9_.:-]*$');

  /// The document's single root element.
  static XmlElement parse(String xml) => XmlReader._(xml.startsWith('﻿') ? xml.substring(1) : xml)._document();

  Never _fail(String why) => throw FormatException('Malformed XML: $why');

  bool _at(String p) => _s.startsWith(p, _i);

  bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

  void _skipWs() {
    while (_i < _s.length && _isWs(_s.codeUnitAt(_i))) {
      _i++;
    }
  }

  void _skipUntil(String end, String what) {
    final j = _s.indexOf(end, _i);
    if (j == -1) _fail('unterminated $what');
    _i = j + end.length;
  }

  XmlElement _document() {
    _skipWs();
    if (_at('<?xml')) _skipUntil('?>', 'declaration');
    XmlElement? root;
    while (true) {
      _skipWs();
      if (_i >= _s.length) break;
      if (_at('<!--')) {
        _skipUntil('-->', 'comment');
      } else if (_at('<?')) {
        _skipUntil('?>', 'instruction');
      } else if (_at('<!')) {
        _fail('DOCTYPE and declarations are not accepted');
      } else if (_at('<') && root == null) {
        root = _element(const {'xml': _xmlNs}, 0);
      } else {
        _fail('content outside the single root element');
      }
    }
    return root ?? _fail('no root element');
  }

  String _name() {
    final start = _i;
    while (_i < _s.length && !_isWs(_s.codeUnitAt(_i)) && !'<>/=\'"'.contains(_s[_i])) {
      _i++;
    }
    final n = _s.substring(start, _i);
    if (!_nameChars.hasMatch(n)) _fail('bad name');
    return n;
  }

  XmlElement _element(Map<String, String> scope, int depth) {
    if (depth > _maxDepth) _fail('nested too deeply');
    _i++; // <
    final qname = _name();
    final attrs = <String, String>{};
    var selfClosing = false;
    while (true) {
      _skipWs();
      if (_i >= _s.length) _fail('unterminated tag');
      if (_at('/>')) {
        _i += 2;
        selfClosing = true;
        break;
      }
      if (_at('>')) {
        _i++;
        break;
      }
      final key = _name();
      _skipWs();
      if (!_at('=')) _fail('attribute without a value');
      _i++;
      _skipWs();
      if (_i >= _s.length || (_s[_i] != '"' && _s[_i] != "'")) _fail('unquoted attribute');
      final quote = _s[_i++];
      final end = _s.indexOf(quote, _i);
      if (end == -1) _fail('unterminated attribute');
      final raw = _s.substring(_i, end);
      if (raw.contains('<')) _fail('"<" inside an attribute');
      _i = end + 1;
      if (attrs.containsKey(key)) _fail('duplicate attribute');
      attrs[key] = _decode(raw);
    }
    final inner = {...scope};
    attrs.forEach((k, v) {
      if (k == 'xmlns') inner[''] = v;
      if (k.startsWith('xmlns:')) inner[k.substring(6)] = v;
    });
    final colon = qname.indexOf(':');
    final prefix = colon == -1 ? '' : qname.substring(0, colon);
    final local = colon == -1 ? qname : qname.substring(colon + 1);
    final ns = inner[prefix];
    if (ns == null && prefix.isNotEmpty) _fail('unbound namespace prefix');
    final element = XmlElement(ns ?? '', local);
    if (selfClosing) return element;
    while (true) {
      if (_i >= _s.length) _fail('element "$qname" is not closed');
      if (_at('</')) {
        _i += 2;
        final closing = _name();
        _skipWs();
        if (!_at('>')) _fail('bad end tag');
        _i++;
        if (closing != qname) _fail('mismatched end tag');
        return element;
      }
      if (_at('<!--')) {
        _skipUntil('-->', 'comment');
      } else if (_at('<![CDATA[')) {
        final j = _s.indexOf(']]>', _i);
        if (j == -1) _fail('unterminated CDATA');
        element._text.write(_s.substring(_i + 9, j));
        _i = j + 3;
      } else if (_at('<?')) {
        _skipUntil('?>', 'instruction');
      } else if (_at('<!')) {
        _fail('declaration inside an element');
      } else if (_at('<')) {
        element.children.add(_element(inner, depth + 1));
      } else {
        final j = _s.indexOf('<', _i);
        if (j == -1) _fail('element "$qname" is not closed');
        element._text.write(_decode(_s.substring(_i, j)));
        _i = j;
      }
    }
  }

  String _decode(String raw) {
    if (!raw.contains('&')) return raw;
    final entity = RegExp(r'&(#x[0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]+);');
    if (raw.replaceAll(entity, '').contains('&')) _fail('a bare "&"');
    return raw.replaceAllMapped(entity, (m) {
      final e = m.group(1)!;
      switch (e) {
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'amp':
          return '&';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      if (e.startsWith('#')) {
        final code = e.startsWith('#x') ? int.parse(e.substring(2), radix: 16) : int.parse(e.substring(1));
        if (code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff)) return String.fromCharCode(code);
      }
      _fail('unknown entity');
    });
  }
}
